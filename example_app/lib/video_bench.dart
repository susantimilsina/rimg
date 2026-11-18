// Video checks for rimg_video. Put test clips (benchmark/make_test_videos.sh)
// in <app files>/video_in (adb push / simctl), run with
// --dart-define=BENCH=video. Results: screen, logs (RIMGBENCH) and
// Documents/results.txt; outputs go to <app files>/video_out.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rimg_video/rimg_video.dart';

class VideoBenchPage extends StatefulWidget {
  const VideoBenchPage({super.key});
  @override
  State<VideoBenchPage> createState() => _VideoBenchPageState();
}

class _VideoBenchPageState extends State<VideoBenchPage> {
  final lines = <String>[];

  void log(String s) {
    // ignore: avoid_print
    print('RIMGBENCH $s');
    setState(() => lines.add(s));
    getApplicationDocumentsDirectory().then(
      (d) => File(
        '${d.path}/results.txt',
      ).writeAsStringSync('${lines.join('\n')}\n'),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => run().catchError((Object e) => log('FAILED: $e')),
    );
  }

  String mb(int bytes) => '${(bytes / 1e6).toStringAsFixed(2)} MB';

  Future<RimgVideoOutput> timed(
    String label,
    String input,
    String output, {
    int maxSize = 1280,
    int targetBytes = 0,
    RimgVideoCodec codec = RimgVideoCodec.h264,
  }) async {
    final sw = Stopwatch()..start();
    final job = RimgVideo.compress(
      inputPath: input,
      outputPath: output,
      maxSize: maxSize,
      targetBytes: targetBytes,
      codec: codec,
    );
    var updates = 0;
    job.progress.listen((_) => updates++);
    final out = await job.result;
    log(
      '  ${label.padRight(22)} ${sw.elapsedMilliseconds.toString().padLeft(6)} ms  '
      '${out.width}x${out.height}  ${mb(out.fileBytes)}  ${out.duration.inMilliseconds} ms  '
      'reencoded=${out.reencoded} codec=${out.codec?.name}  progress=$updates',
    );
    return out;
  }

  Future<void> run() async {
    final base = Platform.isAndroid
        ? (await getExternalStorageDirectory())!
        : await getApplicationDocumentsDirectory();
    final inDir = Directory('${base.path}/video_in');
    final outDir = Directory('${base.path}/video_out')
      ..createSync(recursive: true);
    log('${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    if (!inDir.existsSync()) return log('no input dir ${inDir.path}');

    final files = inDir.listSync().whereType<File>().map((f) => f.path).toList()
      ..sort();
    for (final path in files) {
      final name = path.split('/').last;
      final stem = name.split('.').first;
      log('--- $name  ${mb(File(path).lengthSync())}');
      if (name.startsWith('corrupt')) {
        try {
          await RimgVideo.probe(path);
          log('  probe: UNEXPECTED success');
        } on RimgVideoException catch (e) {
          log('  probe -> ${e.code} (ok)');
        }
        try {
          await RimgVideo.compress(
            inputPath: path,
            outputPath: '${outDir.path}/$stem.mp4',
          ).result;
          log('  compress: UNEXPECTED success');
        } on RimgVideoException catch (e) {
          log('  compress -> ${e.code} (ok): ${e.message.split('\n').first}');
        }
        continue;
      }
      try {
        await checkFile(path, name, stem, outDir);
      } catch (e) {
        log('  FAILED: $e');
      }
    }
    log('outputs in ${outDir.path}');
    log('DONE');
  }

  Future<void> checkFile(
    String path,
    String name,
    String stem,
    Directory outDir,
  ) async {
    {
      final info = await RimgVideo.probe(path);
      log('  $info');
      await timed('h264 1280', path, '${outDir.path}/${stem}__h264_1280.mp4');
      if (name.startsWith('landscape')) {
        await timed(
          'hevc 1280',
          path,
          '${outDir.path}/${stem}__hevc_1280.mp4',
          codec: RimgVideoCodec.hevc,
        );
        await timed(
          'h264 1920',
          path,
          '${outDir.path}/${stem}__h264_1920.mp4',
          maxSize: 1920,
        );
        final o = await timed(
          'target 2 MB',
          path,
          '${outDir.path}/${stem}__target2mb.mp4',
          targetBytes: 2000000,
        );
        log(
          '  target 2 MB -> ${o.fileBytes <= 2000000 * 1.1 ? 'within 10%' : 'OVER by ${(o.fileBytes / 2e6 * 100 - 100).round()}%'}',
        );
      }
      if (name.startsWith('no_audio_4k')) {
        // Cancel mid-way: result must fail with "cancelled" and leave no file.
        final out = '${outDir.path}/${stem}__cancelled.mp4';
        final job = RimgVideo.compress(
          inputPath: path,
          outputPath: out,
          maxSize: 1920,
        );
        final sw = Stopwatch()..start();
        job.progress
            .firstWhere((p) => p > 0.2)
            .then((_) => job.cancel(), onError: (_) {});
        try {
          await job.result;
          log('  cancel: UNEXPECTED success (finished before cancel?)');
        } on RimgVideoException catch (e) {
          log(
            '  cancel -> ${e.code} after ${sw.elapsedMilliseconds} ms, file left: ${File(out).existsSync()}',
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('rimg_video checks')),
    body: ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final l in lines)
          Text(
            l,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
      ],
    ),
  );
}
