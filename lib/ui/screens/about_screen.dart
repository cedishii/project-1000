import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app.dart';
import '../store_scope.dart';
import '../theme.dart';
import '../widgets/emblem.dart';

const author = 'Cedrick Miguel P. Kaneko';
const repositoryUrl = 'https://github.com/cedishii/project-1000';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.5,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
        children: [
          const LogoBanner(),
          const SizedBox(height: 20),
          Text(appName, style: display(28)),
          Text(appTagline, style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snap) => Text(
              snap.hasData
                  ? 'Version ${snap.data!.version} (${snap.data!.buildNumber})'
                  : ' ',
              style: muted,
            ),
          ),
          const SizedBox(height: 20),
          _Section(
            title: 'Author',
            child: Text(
              'Created by $author.\n© ${DateTime.now().year} $author.',
              style: muted,
            ),
          ),
          _Section(
            title: 'Privacy',
            child: Text(
              StoreScope.of(context).isLocal
                  ? 'Your list, memories and photos are stored only on this '
                        'device. There are no ads, no analytics and no '
                        'tracking. Unless you sign in to a Project: 1000 '
                        'account, the app makes no network requests, and your '
                        'data leaves this device only when you export a '
                        'backup yourself.'
                  : 'Your list, memories and photos are stored in your '
                        'Project: 1000 account, which only you can open — not '
                        'the owner, not other members. Friends see only what '
                        'you choose to share (Privacy and sharing); your list '
                        'and memories stay private unless you share them. '
                        'There are no ads, '
                        'no analytics and no tracking.',
              style: muted,
            ),
          ),
          _Section(
            title: 'Open source',
            child: Text(
              'Project: 1000 is open-source software released under the MIT '
              'License.\nSource code: $repositoryUrl',
              style: muted,
            ),
          ),
          _Section(
            title: 'Licenses',
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: () => showLicensePage(
                  context: context,
                  applicationName: appName,
                  applicationLegalese: '© $author',
                  applicationIcon: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Emblem(size: 64),
                  ),
                ),
                child: const Text('Open-source licenses'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: display(18, weight: 500)),
        const SizedBox(height: 6),
        child,
      ],
    ),
  );
}
