import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'canvas_editor.dart';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xff101010),
      colorScheme: const ColorScheme.dark(primary: Colors.white),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xff222222),
          foregroundColor: Colors.white,
        ),
      ),
    ),
    home: const Recorder(),
  );
}

enum SessionStatus { idle, running, finished }

class CaptureItem {
  CaptureItem({required this.id, required this.imagePath, this.comment = ''});
  final String id;
  final String imagePath;
  final String comment;
}

class RecordingSession {
  RecordingSession({required this.projectName, required this.projectPath})
    : startedAt = DateTime.now();
  final String projectName;
  final String projectPath;
  final DateTime startedAt;
  final List<CaptureItem> captures = <CaptureItem>[];
  int currentFrameId = 0;
  SessionStatus status = SessionStatus.running;

  Directory get screenshotsDirectory =>
      Directory('$projectPath${Platform.pathSeparator}Screenshots');
  Directory get textsDirectory =>
      Directory('$projectPath${Platform.pathSeparator}Texte');
  Directory get exportDirectory =>
      Directory('$projectPath${Platform.pathSeparator}Export');
}

class Recorder extends StatefulWidget {
  const Recorder({super.key});
  @override
  State<Recorder> createState() => _RecorderState();
}

class _RecorderState extends State<Recorder> {
  final projectName = TextEditingController();
  final folder = TextEditingController();
  final comment = TextEditingController();
  RecordingSession? session;
  String status = 'Bereit';
  bool busy = false;
  bool voiceActive = false;

  static const _overlayChannel = MethodChannel(
    'screenshot_story_recorder/overlay',
  );

  bool get isRunning => session?.status == SessionStatus.running;

  @override
  void initState() {
    super.initState();
    _overlayChannel.setMethodCallHandler(_handleOverlayMessage);
  }

  Future<void> _handleOverlayMessage(MethodCall call) async {
    if (!mounted) return;
    switch (call.method) {
      case 'capture':
        await capture(mode: call.arguments as String? ?? 'screen');
        break;
      case 'voiceState':
        final voiceState = call.arguments as String? ?? 'error';
        setState(() {
          voiceActive = voiceState == 'recording';
          status = switch (voiceState) {
            'recording' => 'Aufnahme läuft ...',
            'localUnavailable' =>
              'Lokale Spracherkennung ist auf diesem Mac nicht verfügbar',
            'error' => 'Spracherkennung konnte nicht gestartet werden',
            _ => status,
          };
        });
        break;
      case 'voiceText':
        await _saveVoiceComment(call.arguments as String? ?? '');
        break;
    }
  }

  @override
  void dispose() {
    projectName.dispose();
    folder.dispose();
    comment.dispose();
    super.dispose();
  }

  Future<void> chooseFolder() async {
    if (Platform.isWindows) {
      final selected = await _overlayChannel.invokeMethod<String>(
        'chooseFolder',
      );
      if (!mounted || selected == null || selected.trim().isEmpty) return;
      setState(() {
        folder.text = selected.trim();
        status = 'Speicherort gewählt';
      });
      return;
    }
    if (!Platform.isMacOS) {
      setState(
        () => status = 'Ordnerauswahl wird auf dieser Plattform nicht unterstützt',
      );
      return;
    }
    final result = await Process.run('osascript', <String>[
      '-e',
      'POSIX path of (choose folder with prompt "Speicherort wählen")',
    ]);
    final selected = result.stdout.toString().trim();
    if (!mounted || selected.isEmpty) return;
    setState(() {
      folder.text = selected;
      status = 'Speicherort gewählt';
    });
  }

  String _safeProjectName(String value) {
    final cleaned = value.trim().replaceAll(RegExp(r'[/\\:]'), '_');
    return cleaned.isEmpty ? 'Screenshot Session' : cleaned;
  }

  Future<void> startSession() async {
    if (busy || folder.text.trim().isEmpty) {
      if (folder.text.trim().isEmpty) {
        setState(() => status = 'Bitte zuerst einen Speicherort wählen');
      }
      return;
    }
    setState(() => busy = true);
    try {
      final name = _safeProjectName(projectName.text);
      final projectPath = '${folder.text.trim()}${Platform.pathSeparator}$name';
      final projectDirectory = Directory(projectPath);
      final s2sDirectories = <Directory>[
        Directory('${projectPath}${Platform.pathSeparator}Screenshots'),
        Directory('${projectPath}${Platform.pathSeparator}Texte'),
        Directory('${projectPath}${Platform.pathSeparator}Export'),
      ];
      final existingS2sDirectory = (await Future.wait<bool>(
        s2sDirectories.map((directory) => directory.exists()),
      )).any((exists) => exists);
      if (existingS2sDirectory) {
        throw StateError(
          'Dieses S2S-Projekt existiert bereits. Bitte einen neuen Projektnamen wählen.',
        );
      }
      final newSession = RecordingSession(
        projectName: name,
        projectPath: projectPath,
      );
      await Future.wait(<Future<void>>[
        projectDirectory.create(recursive: true),
        newSession.screenshotsDirectory.create(recursive: true),
        newSession.textsDirectory.create(recursive: true),
        newSession.exportDirectory.create(recursive: true),
      ]);
      if (!mounted) return;
      setState(() {
        session = newSession;
        status = 'Aufnahme läuft';
        busy = false;
      });
      await _overlayChannel.invokeMethod<void>('showToolbar');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        status = 'Session konnte nicht gestartet werden: $error';
        busy = false;
      });
    }
  }

  Future<void> capture({String mode = 'screen'}) async {
    final activeSession = session;
    if (busy || activeSession == null || !isRunning) return;
    if (!Platform.isMacOS && !Platform.isWindows) {
      setState(
        () => status = 'Screenshot-Aufnahme wird auf dieser Plattform nicht unterstützt',
      );
      return;
    }
    setState(() {
      busy = true;
      status = 'Screenshot wird aufgenommen ...';
    });
    try {
      // In continuous voice mode, close the previous spoken segment before
      // creating the next frame. The native recognizer keeps running and the
      // following words belong to the new frame.
      if (voiceActive) {
        final segment = await _overlayChannel.invokeMethod<String>(
          'voiceBoundary',
        );
        if (segment != null && segment.trim().isNotEmpty) {
          await _saveVoiceComment(segment);
        }
      }
      await _overlayChannel.invokeMethod<void>('hideToolbar');
      await Future<void>.delayed(const Duration(milliseconds: 350));
      final id = (activeSession.currentFrameId + 1).toString().padLeft(4, '0');
      final imagePath =
          '${activeSession.screenshotsDirectory.path}${Platform.pathSeparator}$id.png';
      final captureMethod = switch (mode) {
        'region' => 'captureRegion',
        'window' => 'captureWindow',
        _ => 'captureScreen',
      };
      await _overlayChannel.invokeMethod<void>(captureMethod, <String, Object>{
        'path': imagePath,
      });
      if (!File(imagePath).existsSync()) {
        throw StateError('Bildschirmaufnahme ist fehlgeschlagen');
      }
      final textPath =
          '${activeSession.textsDirectory.path}${Platform.pathSeparator}$id.txt';
      final text = comment.text.trim();
      await File(textPath).writeAsString(text);
      activeSession.currentFrameId = int.parse(id);
      activeSession.captures.add(
        CaptureItem(id: id, imagePath: imagePath, comment: text),
      );
      comment.clear();
      if (!mounted) return;
      setState(() {
        status = '${activeSession.projectName} Nr. ${int.parse(id)}';
        busy = false;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('${activeSession.projectName} Nr. ${int.parse(id)}'),
            duration: const Duration(seconds: 2),
          ),
        );
      await _overlayChannel.invokeMethod<void>('showToolbar');
      await _overlayChannel.invokeMethod<void>(
        'captureConfirmation',
        '${activeSession.projectName} Nr. ${int.parse(id)}',
      );
    } catch (error) {
      await _overlayChannel.invokeMethod<void>('showToolbar');
      if (!mounted) return;
      setState(() {
        status = 'Screenshot fehlgeschlagen: $error';
        busy = false;
      });
    }
  }

  Future<void> _saveVoiceComment(String value) async {
    final activeSession = session;
    final text = value.trim();
    if (activeSession == null || !isRunning || text.isEmpty) return;
    if (activeSession.currentFrameId == 0) {
      setState(() => status = 'Bitte zuerst ein Foto aufnehmen');
      return;
    }
    final id = activeSession.currentFrameId.toString().padLeft(4, '0');
    final textPath =
        '${activeSession.textsDirectory.path}${Platform.pathSeparator}$id.txt';
    await File(textPath).writeAsString(text);
    final index = activeSession.captures.indexWhere((item) => item.id == id);
    if (index >= 0) {
      activeSession.captures[index] = CaptureItem(
        id: id,
        imagePath: activeSession.captures[index].imagePath,
        comment: text,
      );
    }
    if (mounted) setState(() => status = 'Kommentar für $id gespeichert');
  }

  Future<void> finishSession() async {
    final activeSession = session;
    if (busy || activeSession == null || !isRunning) return;
    setState(() {
      busy = true;
      status = 'Vorschau wird geöffnet ...';
    });
    try {
      await _overlayChannel.invokeMethod<void>('hideToolbar');
      if (!mounted) return;
      final editedItems = await showDialog<List<CaptureItem>>(
        context: context,
        barrierDismissible: false,
        builder: (context) =>
            _ExportPreviewDialog(items: activeSession.captures),
      );
      if (!mounted) return;
      if (editedItems == null) {
        await _overlayChannel.invokeMethod<void>('showToolbar');
        setState(() {
          status = 'Vorschau abgebrochen';
          busy = false;
        });
        return;
      }

      setState(() => status = 'Storyboard wird erstellt ...');
      await _applyPreviewChanges(activeSession, editedItems);
      final paths = await _exportStoryboards(activeSession);
      activeSession.status = SessionStatus.finished;
      setState(() {
        status = paths.isEmpty
            ? 'Session beendet (keine Screenshots vorhanden)'
            : 'Session beendet · ${paths.length} Storyboard(s) exportiert';
        busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        status = 'Export fehlgeschlagen: $error';
        busy = false;
      });
    }
  }

  Future<void> _applyPreviewChanges(
    RecordingSession activeSession,
    List<CaptureItem> editedItems,
  ) async {
    final remainingIds = editedItems.map((item) => item.id).toSet();
    final sourceImagePaths = activeSession.captures
        .map((item) => item.imagePath)
        .toSet();
    final sourceTextPaths = activeSession.captures
        .map(
          (item) =>
              '${activeSession.textsDirectory.path}${Platform.pathSeparator}${item.id}.txt',
        )
        .toSet();
    for (var index = 0; index < editedItems.length; index++) {
      final finalId = (index + 1).toString().padLeft(4, '0');
      final finalImagePath =
          '${activeSession.screenshotsDirectory.path}${Platform.pathSeparator}$finalId.png';
      final finalTextPath =
          '${activeSession.textsDirectory.path}${Platform.pathSeparator}$finalId.txt';
      if (await File(finalImagePath).exists() &&
          !sourceImagePaths.contains(finalImagePath)) {
        throw StateError('Zieldatei existiert bereits: $finalImagePath');
      }
      if (await File(finalTextPath).exists() &&
          !sourceTextPaths.contains(finalTextPath)) {
        throw StateError('Zieldatei existiert bereits: $finalTextPath');
      }
    }

    for (final item in activeSession.captures) {
      if (remainingIds.contains(item.id)) continue;
      final imageFile = File(item.imagePath);
      final textFile = File(
        '${activeSession.textsDirectory.path}${Platform.pathSeparator}${item.id}.txt',
      );
      if (await imageFile.exists()) await imageFile.delete();
      if (await textFile.exists()) await textFile.delete();
    }

    final token = DateTime.now().microsecondsSinceEpoch;
    final temporaryImages = <String, String>{};
    final temporaryTexts = <String, String>{};
    for (var index = 0; index < editedItems.length; index++) {
      final item = editedItems[index];
      final imageFile = File(item.imagePath);
      final temporaryImagePath =
          '${activeSession.screenshotsDirectory.path}${Platform.pathSeparator}.s2s-reorder-$token-$index.png';
      if (!await imageFile.exists()) {
        throw StateError('Screenshot fehlt: ${item.imagePath}');
      }
      await imageFile.rename(temporaryImagePath);
      temporaryImages[item.id] = temporaryImagePath;

      final textFile = File(
        '${activeSession.textsDirectory.path}${Platform.pathSeparator}${item.id}.txt',
      );
      if (await textFile.exists()) {
        final temporaryTextPath =
            '${activeSession.textsDirectory.path}${Platform.pathSeparator}.s2s-reorder-$token-$index.txt';
        await textFile.rename(temporaryTextPath);
        temporaryTexts[item.id] = temporaryTextPath;
      }
    }

    final finalizedItems = <CaptureItem>[];
    for (var index = 0; index < editedItems.length; index++) {
      final item = editedItems[index];
      final finalId = (index + 1).toString().padLeft(4, '0');
      final finalImagePath =
          '${activeSession.screenshotsDirectory.path}${Platform.pathSeparator}$finalId.png';
      final finalTextPath =
          '${activeSession.textsDirectory.path}${Platform.pathSeparator}$finalId.txt';
      await File(temporaryImages[item.id]!).rename(finalImagePath);
      final temporaryTextPath = temporaryTexts[item.id];
      if (temporaryTextPath != null) {
        await File(temporaryTextPath).rename(finalTextPath);
      }
      await File(finalTextPath).writeAsString(item.comment.trim());
      finalizedItems.add(
        CaptureItem(
          id: finalId,
          imagePath: finalImagePath,
          comment: item.comment.trim(),
        ),
      );
    }
    activeSession.captures
      ..clear()
      ..addAll(finalizedItems);
  }

  Future<List<File>> _exportStoryboards(RecordingSession activeSession) async {
    const cellWidth = 440.0;
    const imageHeight = 248.0;
    const commentHeight = 140.0;
    const gap = 20.0;
    const padding = 24.0;
    const cellHeight = imageHeight + commentHeight;
    final output = <File>[];
    final totalItems = activeSession.captures.length;
    if (totalItems == 0) return output;
    final pageCount = (totalItems + 8) ~/ 9;
    final basePageSize = totalItems ~/ pageCount;
    final largerPageCount = totalItems % pageCount;
    var pageStart = 0;
    for (var pageIndex = 0; pageIndex < pageCount; pageIndex++) {
      final pageSize = basePageSize + (pageIndex < largerPageCount ? 1 : 0);
      final pageItems = activeSession.captures
          .skip(pageStart)
          .take(pageSize)
          .toList();
      pageStart += pageSize;
      final columns = pageSize <= 3 ? pageSize : 3;
      final rows = (pageSize + columns - 1) ~/ columns;
      final canvasWidth =
          padding * 2 + columns * cellWidth + (columns - 1) * gap;
      final canvasHeight = padding * 2 + rows * cellHeight + (rows - 1) * gap;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..drawColor(Colors.white, BlendMode.src);
      final imagePaint = Paint()..filterQuality = FilterQuality.high;
      var index = 0;
      for (final item in pageItems) {
        final image = await _decode(await File(item.imagePath).readAsBytes());
        final column = index % columns;
        final row = index ~/ columns;
        final left = padding + column * (cellWidth + gap);
        final top = padding + row * (cellHeight + gap);
        final imageRect = Rect.fromLTWH(left, top, cellWidth, imageHeight);
        final commentRect = Rect.fromLTWH(
          left,
          top + imageHeight,
          cellWidth,
          commentHeight,
        );
        canvas.drawRect(imageRect, Paint()..color = Colors.black);
        canvas.drawImageRect(
          image,
          _coverRect(
            image.width.toDouble(),
            image.height.toDouble(),
            imageRect,
          ),
          imageRect,
          imagePaint,
        );
        canvas.drawRect(commentRect, Paint()..color = Colors.black);
        _drawText(
          canvas,
          item.comment.isEmpty ? 'Kommentar' : item.comment,
          commentRect,
        );
        index++;
      }
      final picture = recorder.endRecording();
      final rendered = await picture.toImage(
        canvasWidth.toInt(),
        canvasHeight.toInt(),
      );
      final png = await rendered.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) {
        throw StateError('Storyboard konnte nicht kodiert werden');
      }
      final page = pageIndex + 1;
      final file = File(
        '${activeSession.exportDirectory.path}${Platform.pathSeparator}Storyboard_${page.toString().padLeft(3, '0')}.png',
      );
      await file.writeAsBytes(png.buffer.asUint8List());
      output.add(file);
    }
    return output;
  }

  Future<ui.Image> _decode(Uint8List bytes) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(bytes, completer.complete);
    return completer.future;
  }

  Rect _coverRect(double width, double height, Rect destination) {
    final scale = (destination.width / width > destination.height / height)
        ? destination.width / width
        : destination.height / height;
    final sourceWidth = destination.width / scale;
    final sourceHeight = destination.height / scale;
    return Rect.fromLTWH(
      (width - sourceWidth) / 2,
      (height - sourceHeight) / 2,
      sourceWidth,
      sourceHeight,
    );
  }

  void _drawText(Canvas canvas, String value, Rect rect) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: const TextStyle(color: Colors.white, fontSize: 18, height: 1.25),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 5,
      ellipsis: '…',
    )..layout(maxWidth: rect.width - 24);
    painter.paint(canvas, Offset(rect.left + 12, rect.top + 10));
  }

  @override
  Widget build(BuildContext context) {
    final activeSession = session;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Image.asset(
                  'Assets/AppIconScreen2Story.png',
                  width: 112,
                  height: 112,
                  fit: BoxFit.contain,
                ),
                const SizedBox(height: 18),
                const Text(
                  'S2S',
                  style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                const Text(
                  'Screen 2 Story',
                  style: TextStyle(fontSize: 18, color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 36),
                TextField(
                  controller: projectName,
                  enabled: !isRunning,
                  decoration: const InputDecoration(labelText: 'Projektname'),
                ),
                const SizedBox(height: 16),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: folder,
                        readOnly: true,
                        decoration: const InputDecoration(
                          labelText: 'Speicherort',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      onPressed: isRunning || busy ? null : chooseFolder,
                      child: const Text('Auswählen'),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                if (!isRunning)
                  ElevatedButton.icon(
                    onPressed: busy ? null : startSession,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Session starten'),
                  ),
                if (isRunning) ...<Widget>[
                  _StatusCard(session: activeSession!),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: busy ? null : finishSession,
                      icon: const Icon(Icons.stop),
                      label: const Text('Session beenden · Export erstellen'),
                    ),
                  ),
                ],
                const SizedBox(height: 28),
                Text(status, textAlign: TextAlign.center),
                if (activeSession != null && !isRunning)
                  Text(
                    'Export: ${activeSession.exportDirectory.path}',
                    textAlign: TextAlign.center,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.session});
  final RecordingSession session;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: <Widget>[
          const Text('🟢 Aufnahme läuft'),
          Text('Fotos: ${session.captures.length}'),
          Text(
            'Notizen: ${session.captures.where((item) => item.comment.isNotEmpty).length}',
          ),
        ],
      ),
    ),
  );
}

class _ExportPreviewDialog extends StatefulWidget {
  const _ExportPreviewDialog({required this.items});

  final List<CaptureItem> items;

  @override
  State<_ExportPreviewDialog> createState() => _ExportPreviewDialogState();
}

class _ExportPreviewDialogState extends State<_ExportPreviewDialog> {
  late final List<CaptureItem> items = List<CaptureItem>.of(widget.items);

  void _updateComment(int index, String comment) {
    final item = items[index];
    items[index] = CaptureItem(
      id: item.id,
      imagePath: item.imagePath,
      comment: comment,
    );
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final item = items.removeAt(oldIndex);
      items.insert(newIndex, item);
    });
  }

  Future<void> _editItem(int index) async {
    await showDialog<bool>(
      context: context,
      builder: (context) =>
          CanvasEditorDialog(imagePath: items[index].imagePath),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final width = screen.width > 1050 ? 1000.0 : screen.width - 48;
    final height = screen.height > 760 ? 680.0 : screen.height - 48;
    return Dialog(
      child: SizedBox(
        width: width,
        height: height,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Expanded(
                    child: Text(
                      'Storyboard-Vorschau',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Text('${items.length} Bilder'),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Text bearbeiten, Einträge löschen oder per Griff verschieben.',
              ),
              const SizedBox(height: 16),
              Expanded(
                child: items.isEmpty
                    ? const Center(child: Text('Keine Bilder vorhanden'))
                    : ReorderableListView.builder(
                        buildDefaultDragHandles: false,
                        itemCount: items.length,
                        onReorder: _reorder,
                        itemBuilder: (context, index) {
                          final item = items[index];
                          return Card(
                            key: ValueKey(item.id),
                            margin: const EdgeInsets.only(bottom: 12),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  ReorderableDragStartListener(
                                    index: index,
                                    child: const Padding(
                                      padding: EdgeInsets.only(
                                        top: 42,
                                        right: 12,
                                      ),
                                      child: Icon(Icons.drag_handle),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 220,
                                    height: 138,
                                    child: Image.file(
                                      File(item.imagePath),
                                      fit: BoxFit.cover,
                                      errorBuilder: (context, error, stack) =>
                                          const Center(
                                            child: Icon(Icons.broken_image),
                                          ),
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: TextField(
                                      key: ValueKey('text-${item.id}'),
                                      controller: TextEditingController(
                                        text: item.comment,
                                      ),
                                      maxLines: 4,
                                      decoration: InputDecoration(
                                        labelText:
                                            'Kommentar ${(index + 1).toString().padLeft(4, '0')}',
                                        border: const OutlineInputBorder(),
                                      ),
                                      onChanged: (value) =>
                                          _updateComment(index, value),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Bild bearbeiten',
                                    onPressed: () => _editItem(index),
                                    icon: const Icon(Icons.draw_outlined),
                                  ),
                                  IconButton(
                                    tooltip: 'Bild und Kommentar löschen',
                                    onPressed: () =>
                                        setState(() => items.removeAt(index)),
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      color: Colors.redAccent,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Abbrechen'),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: () => Navigator.of(context).pop(items),
                    icon: const Icon(Icons.file_download_outlined),
                    label: const Text('Export erstellen'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
