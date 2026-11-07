import 'dart:async';

import 'package:background_hiit_timer/cue_player.dart';
import 'package:background_hiit_timer/media_files.dart';
import 'package:flutter/material.dart';
import 'package:openhiit/core/media/media_store.dart';
import 'package:openhiit/core/models/timer_sound_settings.dart';
import 'package:openhiit/core/providers/timer_creation_provider/timer_creation_provider.dart';
import 'package:openhiit/features/edit_timer/ui/widgets/start_save_toggle.dart';
import 'package:openhiit/features/edit_timer/ui/widgets/tabs/sound_tab/constants.dart';
import 'package:openhiit/shared/ui/widgets/media_picker.dart';
import 'package:openhiit_audioplayers/openhiit_audioplayers.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SoundTab extends StatefulWidget {
  final ValueChanged<StartSaveState> onEdited;
  final ScrollController scrollController;
  final bool active;

  const SoundTab(
      {super.key,
      required this.onEdited,
      required this.scrollController,
      this.active = true});

  @override
  SoundTabState createState() => SoundTabState();
}

class SoundTabState extends State<SoundTab> with WidgetsBindingObserver {
  late final CuePlayer _player;
  final Object _previewLease = Object();
  bool _importing = false;
  static const _fields = {
    'workSound': ('work-sound', 'Work Sound'),
    'restSound': ('rest-sound', 'Rest Sound'),
    'halfwaySound': ('halfway-sound', 'Halfway Sound'),
    'countdownSound': ('countdown-sound', 'Countdown Sound'),
    'endSound': ('end-sound', 'End Sound'),
    'breakSound': ('break-sound', 'Break Sound'),
  };

  @override
  void initState() {
    super.initState();
    _player = CuePlayer();
    WidgetsBinding.instance.addObserver(this);
    unawaited(AudioPlayer.global.setAudioContext(
      AudioContextConfig(focus: AudioContextConfigFocus.mixWithOthers).build(),
    ));
  }

  @override
  void didUpdateWidget(SoundTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active) unawaited(stopPreview());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(stopPreview());
    if (state == AppLifecycleState.resumed && mounted) setState(() {});
  }

  Future<void> stopPreview() async {
    await _player.stop();
    MediaStore.instance.release(_previewLease);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_player
        .dispose()
        .whenComplete(() => MediaStore.instance.release(_previewLease)));
    super.dispose();
  }

  Future<void> _preview(String field, String sound) async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted || !widget.active) return;
    MediaStore.instance.retain(_previewLease, [sound]);
    await _player.play(sound, preferences,
        fallback: TimerSoundSettings.defaults[field]!);
    if (mounted) setState(() {});
  }

  void _set(String field, String value) {
    context
        .read<TimerCreationProvider>()
        .setSound(field, value == 'none' ? '' : value);
    widget.onEdited(StartSaveState.save);
  }

  Future<void> _import(String field) async {
    setState(() => _importing = true);
    String? reference;
    try {
      await stopPreview();
      reference = await pickMedia(audio: true);
      if (reference == null || !mounted) return;
      _set(field, reference);
      await _preview(field, reference);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'Unable to import audio. Choose a valid MP3 or WAV file under 20 MB.')),
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
    final settings = provider.timer.soundSettings.toMap();
    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 16),
          child: Text(
              'Import MP3 or WAV files for short cues. New cues replace the previous sound. Countdown cues restart at each countdown tick.'),
        ),
        for (final field in _fields.entries)
          if (field.key != 'breakSound' ||
              (provider.timer.timeSettings.breakTime > 0 &&
                  provider.timer.timeSettings.restarts > 0))
            Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Builder(builder: (context) {
                final raw = settings[field.key] as String;
                final selected = raw.isEmpty ? 'none' : raw;
                final local = MediaFiles.isLocal(selected);
                return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      KeyedSubtree(
                          key: ValueKey('${field.key}-$selected'),
                          child: DropdownButtonFormField<String>(
                            key: ValueKey(field.value.$1),
                            initialValue: selected,
                            isExpanded: true,
                            decoration:
                                InputDecoration(labelText: field.value.$2),
                            items: [
                              for (final option in soundOptions.entries)
                                DropdownMenuItem(
                                    value: option.key,
                                    child: Text(option.value)),
                              if (!soundOptions.containsKey(selected))
                                DropdownMenuItem(
                                    value: selected,
                                    child: Text(
                                      local
                                          ? MediaFiles.displayName(selected)
                                          : selected,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    )),
                            ],
                            onChanged: _importing
                                ? null
                                : (value) async {
                                    if (value == null) return;
                                    await stopPreview();
                                    if (!mounted) return;
                                    _set(field.key, value);
                                    await _preview(field.key, value);
                                  },
                          )),
                      Wrap(spacing: 8, children: [
                        TextButton.icon(
                          key: ValueKey('${field.value.$1}-import'),
                          onPressed:
                              _importing ? null : () => _import(field.key),
                          icon: const Icon(Icons.audio_file_outlined),
                          label: Text(local ? 'Replace audio' : 'Import audio'),
                        ),
                        TextButton.icon(
                          onPressed: _importing || selected == 'none'
                              ? null
                              : () => _preview(field.key, selected),
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Preview'),
                        ),
                        TextButton(
                          onPressed: _importing
                              ? null
                              : () async {
                                  await stopPreview();
                                  if (!mounted) return;
                                  _set(field.key,
                                      TimerSoundSettings.defaults[field.key]!);
                                },
                          child: const Text('Restore default'),
                        ),
                      ]),
                      if (local)
                        FutureBuilder<String?>(
                          future: MediaStore.instance.audioIssue(selected),
                          builder: (context, snapshot) => snapshot.data == null
                              ? const SizedBox.shrink()
                              : Text(
                                  '${snapshot.data} The default sound will be used.',
                                  style: TextStyle(
                                      color:
                                          Theme.of(context).colorScheme.error)),
                        ),
                    ]);
              }),
            ),
        TextButton.icon(
            onPressed: stopPreview,
            icon: const Icon(Icons.stop),
            label: const Text('Stop preview')),
      ],
    );
  }
}
