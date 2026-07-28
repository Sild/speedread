# CloudKit Maintainer Runbook

SpeedRead Pro synchronizes through the user's private CloudKit database. This
runbook documents the reproducible repository-owned configuration without
storing Apple credentials, team identifiers, signing material, device
identifiers, or release evidence.

## Repository-owned configuration

- bundle identifier: `com.sild.speedread.app`
- iCloud container: `iCloud.com.sild.speedread`
- custom private zone: `SpeedReadLibrary`
- schema: `CloudKit/SpeedRead.ckdb`
- record types: `Book`, `BookAsset`, `Tag`, and `BookTag`

Run the credential-free consistency check:

```sh
make cloudkit-check
```

It verifies that the committed schema agrees with Swift record and field names,
entitlements, bundle configuration, and Debug/Release CloudKit environments.

## Container setup

Maintainers with the appropriate Apple Developer role:

1. Register the explicit App ID `com.sild.speedread.app`.
2. Enable CloudKit and Push Notifications for the App ID.
3. Register `iCloud.com.sild.speedread` and associate it with the App ID.
4. In CloudKit Console, confirm the private `SpeedReadLibrary` zone and the
   repository-defined record types.
5. Store any `cktool` management token in Keychain:

   ```sh
   xcrun cktool save-token --type management --method keychain
   ```

6. Validate the committed schema against development:

   ```sh
   make cloudkit-validate-development
   ```

7. After inspecting the exact container identifier, import and verify the
   development schema:

   ```sh
   CONFIRM_CLOUDKIT_IMPORT=iCloud.com.sild.speedread \
       make cloudkit-import-development
   make cloudkit-verify-development
   ```

8. Review the schema in CloudKit Console, deploy it to production, and verify
   the production export:

   ```sh
   make cloudkit-verify-production
   ```

Container registration, schema import, and production deployment mutate Apple
infrastructure. Inspect the selected account and container before each action.

## Release verification

Credential-free CI validates repository consistency but cannot prove live
CloudKit behavior. Before shipping a sync-affecting release, maintainers verify
with signed builds that:

- EPUB and PDF originals, metadata, tags, statuses, and reading positions
  converge between devices;
- deletion, reimport, offline divergence, reinstall, and account changes resolve
  according to the documented merge policy;
- derived PDF text and OCR caches stay device-local;
- reading remains available offline;
- recoverable quota, account, and network failures are presented to the user.

Keep account, signing, device, and test evidence in private release records.

## Apple references

- [Enable app capabilities](https://developer.apple.com/help/account/identifiers/enable-app-capabilities/)
- [Create an iCloud container](https://developer.apple.com/help/account/identifiers/create-an-icloud-container/)
- [Using cktool](https://developer.apple.com/icloud/ck-tool/)
- [CloudKit text-based schemas](https://developer.apple.com/documentation/cloudkit/integrating-a-text-based-schema-into-your-workflow)
