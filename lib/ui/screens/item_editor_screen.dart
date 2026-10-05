import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../feedback.dart';
import '../store_scope.dart';
import '../theme.dart';

/// Create a new item, or edit an existing item's title and description.
class ItemEditorScreen extends StatefulWidget {
  const ItemEditorScreen({super.key, this.item});

  /// Null to create a new item.
  final BucketItem? item;

  @override
  State<ItemEditorScreen> createState() => _ItemEditorScreenState();
}

class _ItemEditorScreenState extends State<ItemEditorScreen> {
  late final _title = TextEditingController(text: widget.item?.title);
  late final _description = TextEditingController(
    text: widget.item?.description,
  );
  final _form = GlobalKey<FormState>();
  bool _saving = false;

  bool get _isNew => widget.item == null;

  bool get _dirty =>
      _title.text.trim() != (widget.item?.title ?? '') ||
      _description.text.trim() != (widget.item?.description ?? '');

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final store = StoreScope.read(context);
    final ok = await guard(context, () async {
      if (_isNew) {
        await store.addItem(_title.text, _description.text);
      } else {
        await store.updateItemText(
          widget.item!.id,
          _title.text,
          _description.text,
        );
      }
    });
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
    } else {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final store = StoreScope.of(context);
    final number = widget.item?.number ?? _nextNumber(store.items);

    return PopScope(
      canPop: _saving || !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final discard = await confirm(
          context,
          title: 'Discard changes?',
          message: 'What you typed hasn\'t been saved.',
          confirmLabel: 'Discard',
          destructive: true,
        );
        if (discard && context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isNew ? 'New thing' : 'Edit ${formatNumber(number)}'),
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
        body: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              Text(
                formatNumber(number),
                style: display(44, color: scheme.secondary),
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _title,
                autofocus: _isNew,
                maxLength: 200,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.next,
                style: display(20, weight: 500),
                decoration: const InputDecoration(
                  labelText: 'What do you want to do?',
                  hintText: 'Something to do before you die',
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Give it a title' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _description,
                minLines: 3,
                maxLines: 10,
                maxLength: 5000,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The number a new item would receive (lowest number not in use).
int _nextNumber(List<BucketItem> items) {
  final used = items.map((i) => i.number).toSet();
  var n = 1;
  while (used.contains(n)) {
    n++;
  }
  return n;
}
