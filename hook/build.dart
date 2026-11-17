import 'dart:io';

import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

void main(List<String> args) async {
  // Xcode runs build hooks with its own PATH, which doesn't include rustup's
  // default install dir. If rustup lives in ~/.cargo/bin but isn't on PATH,
  // re-run this hook once with it prepended.
  final env = Platform.environment;
  final cargoBin = '${env['HOME']}/.cargo/bin';
  final path = env['PATH'] ?? '';
  if (env['RIMG_HOOK_REEXEC'] == null &&
      !path.split(':').contains(cargoBin) &&
      File('$cargoBin/rustup').existsSync()) {
    final child = await Process.start(
      Platform.resolvedExecutable,
      [...Platform.executableArguments, Platform.script.toFilePath(), ...args],
      environment: {'PATH': '$cargoBin:$path', 'RIMG_HOOK_REEXEC': '1'},
      mode: ProcessStartMode.inheritStdio,
    );
    exitCode = await child.exitCode;
    return;
  }

  await build(args, (input, output) async {
    // AVIF output is opt-in (+~2.5 MB per ABI). Apps enable it with
    //   hooks:
    //     user_defines:
    //       rimg:
    //         avif: true
    final avif = input.userDefines['avif'];
    if (avif is! bool?) {
      throw const FormatException('hooks.user_defines.rimg.avif must be true or false');
    }
    await RustBuilder(
      assetName: 'src/rimg_bindings.dart',
      features: [if (avif == true) 'avif'],
    ).run(
      input: input,
      output: output,
    );
    // native_toolchain_rust parses Cargo's .d file by splitting on spaces, so
    // paths containing spaces (e.g. ".../Application Support/...") are lost
    // and the hook never re-runs after a Rust change. Declare them ourselves.
    final rustDir = Directory.fromUri(input.packageRoot.resolve('rust/'));
    for (final e in rustDir.listSync(recursive: true)) {
      final rel = e.path.substring(rustDir.path.length);
      if (rel.startsWith('target') || rel.startsWith('.git')) continue;
      output.dependencies.add(e is Directory ? Uri.directory(e.path) : e.uri);
    }
    output.dependencies.add(Uri.directory(rustDir.path));
  });
}
