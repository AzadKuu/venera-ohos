import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';

Future<void> writeImageToClipboard(Uint8List imageBytes) async {
  const channel = MethodChannel("venera/clipboard");
  if (Platform.isWindows || Platform.isLinux) {
    var image = await instantiateImageCodec(imageBytes);
    var frame = await image.getNextFrame();
    var data = await frame.image.toByteData(format: ImageByteFormat.rawRgba);
    await channel.invokeMethod("writeImageToClipboard", {
      "width": frame.image.width,
      "height": frame.image.height,
      "data": Uint8List.view(data!.buffer),
    });
    image.dispose();
  } else if (Platform.isMacOS) {
    await channel.invokeMethod("writeImageToClipboard", {"data": imageBytes});
  } else if (App.isOhos) {
    // HarmonyOS: try MethodChannel, fallback to unsupported
    try {
      await channel.invokeMethod("writeImageToClipboard", {"data": imageBytes});
    } catch (_) {
      throw UnsupportedError(
        "Clipboard image is not supported on this platform",
      );
    }
  } else {
    throw UnsupportedError("Clipboard image is not supported on this platform");
  }
}
