import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:project_1000/core/log.dart';

import '../../data/models.dart';
import '../feedback.dart';
import '../formatting.dart';
import '../store_scope.dart';
import '../widgets/level_widgets.dart';
import 'avatar_crop_screen.dart';

/// Edit the private profile. Every field is optional.
class ProfileEditorScreen extends StatefulWidget {
  const ProfileEditorScreen({super.key});

  @override
  State<ProfileEditorScreen> createState() => _ProfileEditorScreenState();
}

class _ProfileEditorScreenState extends State<ProfileEditorScreen> {
  late final Profile _original = StoreScope.read(context).profile;
  late final _name = TextEditingController(text: _original.name);
  late final _nickname = TextEditingController(text: _original.nickname);
  late final _age = TextEditingController(text: _original.age?.toString());
  late final _bio = TextEditingController(text: _original.bio);
  late CalendarDate? _started = _original.startedOn;

  /// A newly cropped picture, not saved yet.
  Uint8List? _newPhoto;
  bool _removePhoto = false;
  bool _saving = false;

  bool get _dirty =>
      _name.text.trim() != _original.name ||
      _nickname.text.trim() != _original.nickname ||
      _age.text.trim() != (_original.age?.toString() ?? '') ||
      _bio.text.trim() != _original.bio ||
      _started != _original.startedOn ||
      _newPhoto != null ||
      _removePhoto;

  @override
  void dispose() {
    _name.dispose();
    _nickname.dispose();
    _age.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _choosePhoto(ImageSource source) async {
    XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: source,
        maxWidth: 2560,
        maxHeight: 2560,
        imageQuality: 92,
      );
    } on PlatformException catch (e, s) {
      logError('Photo picker failed', e, s);
      if (mounted) {
        showMessage(context, 'Photos couldn\'t be opened. Please try again.');
      }
      return;
    }
    if (picked == null || !mounted) return;
    final jpeg = await Navigator.push<Uint8List>(
      context,
      MaterialPageRoute(builder: (_) => AvatarCropScreen(path: picked!.path)),
    );
    if (jpeg != null && mounted) {
      setState(() {
        _newPhoto = jpeg;
        _removePhoto = false;
      });
    }
  }

  void _photoOptions() {
    final hasPhoto =
        _newPhoto != null || (_original.photo != null && !_removePhoto);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from photos'),
              onTap: () {
                Navigator.pop(sheet);
                _choosePhoto(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () {
                Navigator.pop(sheet);
                _choosePhoto(ImageSource.camera);
              },
            ),
            if (hasPhoto)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('Remove photo'),
                onTap: () {
                  Navigator.pop(sheet);
                  setState(() {
                    _newPhoto = null;
                    _removePhoto = true;
                  });
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickStarted() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: (_started ?? CalendarDate.today()).toDateTime(),
      firstDate: DateTime(1900),
      lastDate: DateTime(2200),
      helpText: 'Started my 1000 Things on',
    );
    if (picked != null) {
      setState(() => _started = CalendarDate.fromDateTime(picked));
    }
  }

  Future<void> _save() async {
    final ageText = _age.text.trim();
    final age = ageText.isEmpty ? null : int.tryParse(ageText);
    if (ageText.isNotEmpty && (age == null || age > 150)) {
      showMessage(context, 'Age should be a number (or left empty).');
      return;
    }
    setState(() => _saving = true);
    final store = StoreScope.read(context);
    final ok = await guard(context, () async {
      await store.saveProfile(
        Profile(
          name: _name.text,
          nickname: _nickname.text,
          age: age,
          startedOn: _started,
          bio: _bio.text,
        ),
      );
      if (_newPhoto != null) {
        await store.setProfilePhoto(_newPhoto!);
      } else if (_removePhoto) {
        await store.removeProfilePhoto();
      }
    });
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final preview = _removePhoto
        ? _original.copyWith(clearPhoto: true)
        : _original;

    return PopScope(
      canPop: _saving || !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final discard = await confirm(
          context,
          title: 'Discard changes?',
          message: 'Your profile changes haven\'t been saved.',
          confirmLabel: 'Discard',
          destructive: true,
        );
        if (discard && context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Edit profile'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                onPressed: _saving ? null : _save,
                child: const Text('Save'),
              ),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            Center(
              child: GestureDetector(
                onTap: _photoOptions,
                child: Stack(
                  children: [
                    if (_newPhoto != null)
                      ClipOval(
                        child: Image.memory(
                          _newPhoto!,
                          width: 112,
                          height: 112,
                          fit: BoxFit.cover,
                        ),
                      )
                    else
                      ProfileAvatar(
                        profile: Profile(
                          name: _name.text,
                          nickname: _nickname.text,
                          photo: preview.photo,
                        ),
                        size: 112,
                      ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: CircleAvatar(
                        radius: 18,
                        backgroundColor: scheme.primary,
                        child: Icon(
                          Icons.photo_camera_rounded,
                          size: 18,
                          color: scheme.onPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Center(
              child: TextButton(
                onPressed: _photoOptions,
                child: const Text('Change photo'),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _name,
              maxLength: 120,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _nickname,
              maxLength: 60,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Nickname'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _age,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(3),
              ],
              textInputAction: TextInputAction.next,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Age (optional)'),
            ),
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: const Text('Started date'),
                subtitle: Text(
                  _started == null
                      ? 'When you began your 1000 Things — not set'
                      : longDate(_started!),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_started != null)
                      IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => setState(() => _started = null),
                      ),
                    TextButton(
                      onPressed: _pickStarted,
                      child: Text(_started == null ? 'Set' : 'Change'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _bio,
              minLines: 3,
              maxLines: 8,
              maxLength: 1000,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Bio',
                hintText: 'A few words about you',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Your profile stays on this phone. It is never uploaded or '
              'shared, and it is included in your backups.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
