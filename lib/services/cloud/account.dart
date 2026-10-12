import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/log.dart';

/// The cloud project the app connects to, given at build time:
///   flutter build web --dart-define=SUPABASE_URL=… --dart-define=SUPABASE_ANON_KEY=…
/// Without them the app has no cloud features at all (and the phone
/// never connects anywhere).
class CloudConfig {
  static const url = String.fromEnvironment('SUPABASE_URL');
  static const anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  /// Where password-reset and confirmation links lead (the website).
  /// The website itself uses its own address unless one is given; on a
  /// phone, an empty value means the project's Site URL (Supabase Auth
  /// settings).
  static String get siteUrl {
    const configured = String.fromEnvironment('P1000_SITE_URL');
    if (configured.isNotEmpty) return configured;
    return kIsWeb ? Uri.base.origin : '';
  }

  static bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;

  static bool _initialized = false;

  /// Configured and initialized (the client can be used).
  static bool get isReady => _initialized;

  static Future<void> initialize() async {
    if (!isConfigured || _initialized) return;
    await Supabase.initialize(url: url, publishableKey: anonKey);
    _initialized = true;
  }

  static SupabaseClient get client => Supabase.instance.client;
}

enum MemberRole { owner, member }

/// The signed-in account's place in Project: 1000.
sealed class Membership {
  const Membership();
}

class ActiveMember extends Membership {
  const ActiveMember(this.role);
  final MemberRole role;
  bool get isOwner => role == MemberRole.owner;
}

/// Signed in, but the email isn't approved (or isn't confirmed yet).
class NotApproved extends Membership {
  const NotApproved();
}

/// The owner has disabled this account.
class Disabled extends Membership {
  const Disabled();
}

/// Sign-in, sign-up, password and membership for the cloud account.
class Account {
  Account(this.client);

  final SupabaseClient client;
  GoTrueClient get _auth => client.auth;

  User? get user => _auth.currentUser;
  String? get email => user?.email;
  bool get isSignedIn => _auth.currentSession != null;
  Stream<AuthState> get changes => _auth.onAuthStateChange;

  Future<void> signIn(String email, String password) =>
      _auth.signInWithPassword(email: email.trim(), password: password);

  /// Creates a login. Supabase emails a confirmation link first; the
  /// account is usable once the email is confirmed and approved.
  /// Returns true if the user is already signed in (no confirmation
  /// needed on this project).
  Future<bool> signUp(String email, String password) async {
    final res = await _auth.signUp(
      email: email.trim(),
      password: password,
      emailRedirectTo: CloudConfig.siteUrl.isEmpty ? null : CloudConfig.siteUrl,
    );
    return res.session != null;
  }

  Future<void> sendPasswordReset(String email) => _auth.resetPasswordForEmail(
    email.trim(),
    redirectTo: CloudConfig.siteUrl.isEmpty ? null : CloudConfig.siteUrl,
  );

  Future<void> changePassword(String newPassword) =>
      _auth.updateUser(UserAttributes(password: newPassword));

  Future<void> signOut() => _auth.signOut();

  /// The account's membership. An approved email that isn't a member yet
  /// becomes one here (claim_membership).
  Future<Membership> membership() async {
    final claimed = await client.rpc('claim_membership') as String;
    if (claimed == 'not_invited' || claimed == 'not_signed_in') {
      return const NotApproved();
    }
    final row = await client
        .from('members')
        .select('role, status')
        .maybeSingle();
    if (row == null) return const NotApproved();
    if (row['status'] != 'active') return const Disabled();
    return ActiveMember(
      row['role'] == 'owner' ? MemberRole.owner : MemberRole.member,
    );
  }
}

/// Which archive this phone uses: its own (the default) or the signed-in
/// cloud account's. Stored in the app's private folder, outside the
/// archive, so backups never carry it to another phone. The web always
/// uses the cloud.
class DeviceMode {
  DeviceMode(this.root);

  final Directory root;

  File get _file => File(p.join(root.path, 'device.json'));

  Future<bool> usesCloud() async {
    if (kIsWeb) return true;
    try {
      if (!await _file.exists()) return false;
      return (jsonDecode(await _file.readAsString()) as Map)['archive'] ==
          'cloud';
    } catch (e) {
      logError('Could not read device.json', e);
      return false;
    }
  }

  Future<void> setUsesCloud(bool cloud) async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({'archive': cloud ? 'cloud' : 'local'}),
      flush: true,
    );
    await tmp.rename(_file.path);
  }
}
