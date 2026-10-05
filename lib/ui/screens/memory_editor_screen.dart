import 'dart:developer' as dev;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/archive_repository.dart';
import '../../data/models.dart';
import '../../services/photo_storage.dart';
import '../feedback.dart';
import '../formatting.dart';
import '../store_scope.dart';
import '../theme.dart';
import '../widgets/photo_widgets.dart';

/// Write a new memory for an item, or edit an existing one.
class MemoryEditorScreen extends StatefulWidget {
  const MemoryEditorScreen({super.key, required this.item, this.memory});

  final BucketItem item;

  /// Null for a new memory.
  final Memory? memory;

  @override
  State<MemoryEditorScreen> createState() => _MemoryEditorScreenState();
}

class _MemoryEditorScreenState extends State<MemoryEditorScreen> {
  late final _title = TextEditingController(text: widget.memory?.title);
  late final _body = TextEditingController(text: widget.memory?.body);
  late final _location = TextEditingController(text: widget.memory?.location);
  final _tagInput = TextEditingController();
  late CalendarDate _date = widget.memory?.date ?? CalendarDate.today();
  late final List<String> _tags = [...?widget.memory?.hashtags];
  late final List<PhotoRef> _photos = [...?widget.memory?.photos];
  bool _saving = false;
  bool _addingPhotos = false;
  bool _changed = false;

  bool get _isNew => widget.memory == null;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _location.dispose();
    _tagInput.dispose();
    super.dispose();
  }

  void _markChanged() => _changed = true;

  // ------------------------------------------------------------- hashtags

  void _commitTagInput() {
    final tags = parseHashtags(_tagInput.text);
    if (tags.isEmpty) return;
    setState(() {
      for (final t in tags) {
        if (!_tags.contains(t)) _tags.add(t);
      }
      _tagInput.clear();
      _changed = true;
    });
  }

  // --------------------------------------------------------------- photos

  Future<void> _addPhotos(ImageSource source) async {
    final store = StoreScope.read(context);
    final picker = ImagePicker();
    List<XFile> picked;
    try {
      picked = source == ImageSource.camera
          ? [
              ?await picker.pickImage(
                  source: ImageSource.camera,
                  maxWidth: photoMaxSide.toDouble(),
                  maxHeight: photoMaxSide.toDouble(),
                  imageQuality: 88)
            ]
          : await picker.pickMultiImage(
              maxWidth: photoMaxSide.toDouble(),
              maxHeight: photoMaxSide.toDouble(),
              imageQuality: 88);
    } on PlatformException catch (e, s) {
      dev.log('Photo picker failed', error: e, stackTrace: s, name: 'photos');
      if (!mounted) return;
      final denied = e.code.contains('denied') || e.code.contains('access');
      showMessage(
          context,
          denied
              ? 'Project: 1000 isn\'t allowed to use your '
                  '${source == ImageSource.camera ? 'camera' : 'photos'}. '
                  'You can allow it in your phone\'s Settings.'
              : 'Photos couldn\'t be opened. Please try again.');
      return;
    }
    if (picked.isEmpty || !mounted) return;

    setState(() => _addingPhotos = true);
    var failed = 0;
    for (final file in picked) {
      try {
        final ref = await store.photos.addPending(file.path);
        if (!mounted) {
          await store.photos.discard([ref]);
          return;
        }
        setState(() {
          _photos.add(ref);
          _changed = true;
        });
      } catch (e, s) {
        dev.log('Could not add photo', error: e, stackTrace: s, name: 'photos');
        failed++;
        if (isOutOfSpace(e)) {
          if (mounted) showError(context, e, s);
          break;
        }
      }
    }
    if (!mounted) return;
    setState(() => _addingPhotos = false);
    if (failed > 0) {
      showMessage(context,
          '${plural(failed, 'photo')} couldn\'t be added (unsupported or unreadable file).');
    }
  }

  void _choosePhotoSource() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose from gallery'),
            onTap: () {
              Navigator.pop(context);
              _addPhotos(ImageSource.gallery);
            },
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Take a photo'),
            onTap: () {
              Navigator.pop(context);
              _addPhotos(ImageSource.camera);
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _removePhoto(PhotoRef photo) async {
    // Saved photos are only deleted when the memory is saved; pending ones
    // can go right away.
    setState(() {
      _photos.remove(photo);
      _changed = true;
    });
    if (PhotoStorage.isPending(photo)) {
      await StoreScope.read(context).photos.discard([photo]);
    }
  }

  // ----------------------------------------------------------------- save

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date.toDateTime(),
      firstDate: DateTime(1900),
      lastDate: DateTime(2200),
    );
    if (picked != null) {
      setState(() {
        _date = CalendarDate.fromDateTime(picked);
        _changed = true;
      });
    }
  }

  Future<void> _save() async {
    if (_saving || _addingPhotos) return;
    _commitTagInput();
    if (_title.text.trim().isEmpty &&
        _body.text.trim().isEmpty &&
        _photos.isEmpty) {
      showMessage(context, 'Write something or add a photo first.');
      return;
    }
    setState(() => _saving = true);
    final store = StoreScope.read(context);
    final ok = await guard(
      context,
      () => store.saveMemory(MemoryDraft(
        id: widget.memory?.id,
        itemId: widget.item.id,
        title: _title.text,
        body: _body.text,
        date: _date,
        location: _location.text,
        hashtags: _tags,
        photos: _photos,
      )),
    );
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
    } else {
      setState(() => _saving = false);
    }
  }

  Future<void> _discardPending() =>
      StoreScope.read(context).photos.discard(_photos);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    return PopScope(
      canPop: _saving || !_changed,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) {
          if (!_saving) _discardPending();
          return;
        }
        final discard = await confirm(context,
            title: _isNew ? 'Discard this memory?' : 'Discard your changes?',
            message: _isNew
                ? 'What you wrote hasn\'t been saved.'
                : 'The memory stays as it was before you started editing.',
            confirmLabel: 'Discard',
            destructive: true);
        if (discard && context.mounted) {
          await _discardPending();
          if (context.mounted) Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isNew ? 'New memory' : 'Edit memory'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                onPressed: _saving || _addingPhotos ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Save'),
              ),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
          children: [
            Text('${widget.item.label}  ${widget.item.title}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: display(16, weight: 500, color: scheme.secondary)),
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              onChanged: (_) => _markChanged(),
              maxLength: 200,
              textCapitalization: TextCapitalization.sentences,
              style: display(19, weight: 500),
              decoration: const InputDecoration(labelText: 'Title (optional)'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _body,
              onChanged: (_) => _markChanged(),
              minLines: 5,
              maxLines: 20,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'What happened? How did it feel?',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 18),
            Text('Photos', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < _photos.length; i++)
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      PhotoThumb(
                        key: ValueKey(_photos[i].id),
                        photo: _photos[i],
                        size: 92,
                        onTap: () => openPhotoViewer(context, _photos, i),
                      ),
                      Positioned(
                        top: -6,
                        right: -6,
                        child: IconButton.filled(
                          tooltip: 'Remove photo',
                          iconSize: 16,
                          visualDensity: VisualDensity.compact,
                          style: IconButton.styleFrom(
                              backgroundColor: scheme.inverseSurface,
                              foregroundColor: scheme.onInverseSurface),
                          onPressed: () => _removePhoto(_photos[i]),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ),
                    ],
                  ),
                SizedBox(
                  width: 92,
                  height: 92,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _addingPhotos ? null : _choosePhotoSource,
                    child: _addingPhotos
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.add_photo_alternate_outlined),
                              SizedBox(height: 4),
                              Text('Add'),
                            ],
                          ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_outlined),
              title: const Text('Date'),
              subtitle: Text(longDate(_date)),
              trailing:
                  TextButton(onPressed: _pickDate, child: const Text('Change')),
            ),
            TextField(
              controller: _location,
              onChanged: (_) => _markChanged(),
              maxLength: 200,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Location (optional)',
                prefixIcon: Icon(Icons.place_outlined),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _tagInput,
              decoration: InputDecoration(
                labelText: 'Hashtags',
                hintText: '#travel #family',
                prefixIcon: const Icon(Icons.tag_rounded),
                suffixIcon: IconButton(
                  tooltip: 'Add hashtag',
                  icon: const Icon(Icons.add_rounded),
                  onPressed: _commitTagInput,
                ),
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _commitTagInput(),
              onChanged: (v) {
                if (v.endsWith(' ') || v.endsWith(',')) _commitTagInput();
              },
            ),
            if (_tags.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final t in _tags)
                    InputChip(
                      label: Text('#$t'),
                      onDeleted: () => setState(() {
                        _tags.remove(t);
                        _changed = true;
                      }),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
