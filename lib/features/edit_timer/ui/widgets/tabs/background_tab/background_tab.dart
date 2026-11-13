import 'package:background_hiit_timer/media_files.dart';
import 'package:background_hiit_timer/models/interval_stage.dart';
import 'package:flutter/material.dart';
import 'package:openhiit/core/media/media_store.dart';
import 'package:openhiit/core/providers/timer_creation_provider/timer_creation_provider.dart';
import 'package:openhiit/core/utils/interval_calculation.dart';
import 'package:openhiit/features/edit_timer/ui/widgets/start_save_toggle.dart';
import 'package:openhiit/shared/ui/widgets/managed_background.dart';
import 'package:openhiit/shared/ui/widgets/media_picker.dart';
import 'package:provider/provider.dart';

class BackgroundTab extends StatefulWidget {
  const BackgroundTab(
      {super.key, required this.onEdited, required this.scrollController});
  final ValueChanged<StartSaveState> onEdited;
  final ScrollController scrollController;

  @override
  State<BackgroundTab> createState() => _BackgroundTabState();
}

class _BackgroundTabState extends State<BackgroundTab> {
  bool _importing = false;

  Future<void> _choose(IntervalStage stage) async {
    setState(() => _importing = true);
    String? reference;
    try {
      reference = await pickBackgroundImage(context);
      if (reference == null || !mounted) return;
      context
          .read<TimerCreationProvider>()
          .setBackground(stage.name, reference);
      widget.onEdited(StartSaveState.save);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'Unable to import image. Choose a valid JPEG, PNG or WebP file under 20 MB.')),
        );
      }
    } finally {
      if (reference != null) MediaStore.instance.releasePending(reference);
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TimerCreationProvider>();
    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
      children: [
        Text('Background', style: Theme.of(context).textTheme.headlineSmall),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text(
              'Choose a background for each stage, then drag and zoom to crop. Card previews and portrait workouts fill the frame; landscape workouts show the full crop. Clear an image to use the original stage color.'),
        ),
        for (final stage in IntervalStage.values) ...[
          Builder(builder: (context) {
            final reference = provider.timer.backgrounds[stage.name];
            return Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 140,
                    child: Stack(fit: StackFit.expand, children: [
                      ManagedBackground(
                          reference: reference,
                          fit: BoxFit.cover,
                          color: getIntervalColor(stage.label)),
                      Center(
                          child: Text(stage.label,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 24))),
                    ]),
                  ),
                  ListTile(
                    title: Text(
                        reference == null
                            ? 'Stage color'
                            : MediaFiles.displayName(reference),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    subtitle: reference == null
                        ? null
                        : Text(MediaFiles.isCroppedImage(reference)
                            ? 'Custom crop · dark overlay'
                            : 'Centered crop · dark overlay'),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Wrap(spacing: 8, children: [
                      TextButton.icon(
                        key: ValueKey('background-${stage.name}-choose'),
                        onPressed: _importing ? null : () => _choose(stage),
                        icon: const Icon(Icons.image_outlined),
                        label: Text(reference == null
                            ? 'Choose image'
                            : 'Replace image'),
                      ),
                      if (reference != null)
                        TextButton(
                          key: ValueKey('background-${stage.name}-clear'),
                          onPressed: _importing
                              ? null
                              : () {
                                  provider.setBackground(stage.name, null);
                                  widget.onEdited(StartSaveState.save);
                                },
                          child: const Text('Clear'),
                        ),
                    ]),
                  ),
                ],
              ),
            );
          }),
        ],
      ],
    );
  }
}
