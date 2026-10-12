/// Saving a file the app made (a Life Album PDF) in a browser: the
/// browser's own download. Only used on the web.
library;

export 'download_stub.dart' if (dart.library.js_interop) 'download_web.dart';
