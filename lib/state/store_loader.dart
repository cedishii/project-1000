import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';

import '../services/cloud/account.dart';
import '../services/cloud/cloud_archive.dart';
import '../services/cloud/cloud_media.dart';
import 'app_store.dart';

/// The cloud archive can't be opened until the user signs in (or is
/// approved). [membership] says why, when signed in.
class SignInRequired implements Exception {
  const SignInRequired([this.membership]);

  final Membership? membership;
}

/// Opens the archive this device uses:
/// * web: the signed-in cloud account (or [SignInRequired]);
/// * phone: its own archive, unless it was switched to the cloud
///   account and that account is signed in and active. A signed-out or
///   disabled cloud account falls back to the phone's own archive, so the
///   phone's data is never out of reach.
Future<AppStore> loadStore() async {
  await CloudConfig.initialize();
  if (kIsWeb) return openCloudStore();
  final dir = await getApplicationDocumentsDirectory();
  if (CloudConfig.isConfigured &&
      await DeviceMode(dir).usesCloud() &&
      Account(CloudConfig.client).isSignedIn) {
    try {
      return await openCloudStore();
    } on SignInRequired {
      // Fall through to the phone's archive.
    }
  }
  return AppStore.open(root: dir);
}

/// The signed-in account's cloud archive.
Future<AppStore> openCloudStore() async {
  if (!CloudConfig.isConfigured) throw const SignInRequired();
  final client = CloudConfig.client;
  final account = Account(client);
  if (!account.isSignedIn) throw const SignInRequired();
  final membership = await account.membership();
  if (membership is! ActiveMember) throw SignInRequired(membership);
  final media = CloudMedia(client);
  final store = AppStore(
    CloudArchive(client, media),
    media,
    account: account.email,
    isOwner: membership.isOwner,
  );
  await store.load();
  return store;
}
