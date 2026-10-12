import 'package:flutter/material.dart';

import '../../services/cloud/account.dart';
import '../backup_flows.dart';
import '../store_scope.dart';
import 'about_screen.dart';
import 'account_screen.dart';
import 'profile_screen.dart';
import 'reorder_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const _Header('Appearance'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                  value: ThemeMode.system,
                  icon: Icon(Icons.brightness_auto_outlined),
                  label: Text('System'),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  icon: Icon(Icons.light_mode_outlined),
                  label: Text('Light'),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  icon: Icon(Icons.dark_mode_outlined),
                  label: Text('Dark'),
                ),
              ],
              selected: {store.themeMode},
              onSelectionChanged: (s) => store.setThemeMode(s.first),
            ),
          ),
          const _Header('You'),
          ListTile(
            leading: const Icon(Icons.account_circle_outlined),
            title: const Text('Profile'),
            subtitle: const Text('Level, journeys and Life Albums'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ProfileScreen()),
            ),
          ),
          if (CloudConfig.isConfigured) ...[
            const _Header('Account'),
            ListTile(
              leading: Icon(
                store.isLocal
                    ? Icons.cloud_outlined
                    : Icons.cloud_done_outlined,
              ),
              title: Text(store.account ?? 'Project: 1000 account'),
              subtitle: Text(
                store.isLocal
                    ? 'Optional: use your list on the website too'
                    : store.isOwner
                    ? 'Owner · your list is in your account'
                    : 'Your list is in your account',
              ),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AccountScreen()),
              ),
            ),
          ],
          if (store.isLocal) ...[
            const _Header('Data'),
            ListTile(
              leading: const Icon(Icons.upload_file_outlined),
              title: const Text('Export backup'),
              subtitle: const Text(
                'Save everything — every journey, memory, photo and your '
                'profile — to one file',
              ),
              onTap: () => exportFlow(context),
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('Import backup'),
              subtitle: const Text('Restore from a backup file'),
              onTap: () => importFlow(context),
            ),
          ],
          const _Header('List'),
          ListTile(
            leading: const Icon(Icons.swap_vert_rounded),
            title: const Text('Reorder items'),
            subtitle: const Text('Change the order of your list'),
            enabled: store.items.length > 1,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ReorderScreen()),
            ),
          ),
          const _Header('About'),
          ListTile(
            leading: const Icon(Icons.info_outline_rounded),
            title: const Text('About Project: 1000'),
            subtitle: const Text('Version, author, privacy'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AboutScreen()),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}
