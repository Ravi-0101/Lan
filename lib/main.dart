import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart' as shelf_router;
import 'package:uuid/uuid.dart';

void main() => runApp(const LanFileServerApp());

class LanFileServerApp extends StatelessWidget {
  const LanFileServerApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'LAN File Server',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
    home: const HomePage(),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  HttpServer? _server;
  Directory? _shareDir;
  final _password = TextEditingController();
  final _host = TextEditingController(text: '192.168.1.100');
  final _port = TextEditingController(text: '8080');
  final _clientPassword = TextEditingController();
  final _clientUrl = TextEditingController(text: 'http://192.168.1.100:8080');
  final _dio = Dio();
  String? _token;
  String _status = 'Server stopped';
  List<Map<String, dynamic>> _files = [];
  bool _busy = false;

  @override
  void dispose() {
    _password.dispose(); _host.dispose(); _port.dispose();
    _clientPassword.dispose(); _clientUrl.dispose();
    _server?.close(force: true);
    super.dispose();
  }

  Future<Directory> _directory() async {
    _shareDir ??= await getApplicationDocumentsDirectory();
    return _shareDir!;
  }

  Future<void> _chooseFolder() async {
    // For broad folder sharing, use Android/iOS document picker integration.
    // This starter uses the app's private Documents directory as a safe default.
    final dir = await _directory();
    if (mounted) {
      setState(() => _status = 'Sharing app Documents: ${dir.path}');
    }
  }

  Future<void> _startServer() async {
    if (_server != null) return;
    if (_password.text.trim().length < 8) {
      _message('Set a server password of at least 8 characters.');
      return;
    }
    setState(() => _busy = true);
    try {
      final dir = await _directory();
      final router = Router();
      final passwordHash = sha256.convert(utf8.encode(_password.text)).toString();
      final approvedTokens = <String>{};

      router.get('/api/info', (shelf.Request req) => shelf.Response.ok(
        jsonEncode({'name':'LAN File Server','protocol':'HTTP','port':int.parse(_port.text)}),
        headers:{'content-type':'application/json'}));

      router.post('/api/auth', (shelf.Request req) async {
        final body = jsonDecode(await req.readAsString()) as Map<String,dynamic>;
        final candidate = sha256.convert(utf8.encode('${body['password'] ?? ''}')).toString();
        if (candidate != passwordHash) {
          return shelf.Response(401, body:'{"error":"Invalid password"}',
            headers:{'content-type':'application/json'});
        }
        final token = const Uuid().v4();
        approvedTokens.add(token); // Password-authenticated clients are approved in this starter.
        return shelf.Response.ok(jsonEncode({'token':token}),
          headers:{'content-type':'application/json'});
      });

      shelf.Response? auth(shelf.Request req) {
        final token = req.headers['authorization']?.replaceFirst('Bearer ', '');
        if (token == null || !approvedTokens.contains(token)) {
          return shelf.Response(401, body:'{"error":"Authentication required"}',
            headers:{'content-type':'application/json'});
        }
        return null;
      }

      router.get('/api/files', (shelf.Request req) async {
        final denied = auth(req); if (denied != null) return denied;
        final entries = <Map<String,dynamic>>[];
        await for (final e in dir.list()) {
          final stat = await e.stat();
          entries.add({'name':e.uri.pathSegments.where((x)=>x.isNotEmpty).last,
            'directory':stat.type == FileSystemEntityType.directory,
            'size':stat.size});
        }
        return shelf.Response.ok(jsonEncode(entries),
          headers:{'content-type':'application/json'});
      });

      router.get('/api/download', (shelf.Request req) async {
        final denied = auth(req); if (denied != null) return denied;
        final name = req.url.queryParameters['name'];
        if (name == null || name.isEmpty || name.contains('/') || name.contains(r'\') || name == '.' || name == '..') {
          return shelf.Response(400, body:'Invalid filename');
        }
        final file = File('${dir.path}/$name');
        if (!await file.exists()) return shelf.Response.notFound('Not found');
        return shelf.Response.ok(file.openRead(),
          headers:{'content-type':'application/octet-stream',
            'content-disposition':'attachment; filename="$name"'});
      });

      router.post('/api/upload', (shelf.Request req) async {
        final denied = auth(req); if (denied != null) return denied;
        final name = req.url.queryParameters['name'];
        if (name == null || name.isEmpty || name.contains('/') || name.contains(r'\') || name == '.' || name == '..') {
          return shelf.Response(400, body:'Invalid filename');
        }
        final out = File('${dir.path}/$name');
        await out.writeAsBytes(await req.read().expand((x)=>x).toList(), flush:true);
        return shelf.Response.ok('Uploaded');
      });

      router.post('/api/folder', (shelf.Request req) async {
        final denied = auth(req); if (denied != null) return denied;
        final body = jsonDecode(await req.readAsString()) as Map<String,dynamic>;
        final name = (body['name'] ?? '').toString();
        if (name.isEmpty || name.contains('/') || name.contains(r'\') || name == '.' || name == '..') {
          return shelf.Response(400, body:'Invalid folder name');
        }
        await Directory('${dir.path}/$name').create();
        return shelf.Response.ok('Created');
      });

      router.delete('/api/files', (shelf.Request req) async {
        final denied = auth(req); if (denied != null) return denied;
        final name = req.url.queryParameters['name'];
        if (name == null || name.isEmpty || name.contains('/') || name.contains(r'\') || name == '.' || name == '..') {
          return shelf.Response(400, body:'Invalid filename');
        }
        final f = File('${dir.path}/$name');
        final d = Directory('${dir.path}/$name');
        if (await f.exists()) { await f.delete(); return shelf.Response.ok('Deleted'); }
        if (await d.exists()) { await d.delete(recursive:true); return shelf.Response.ok('Deleted'); }
        return shelf.Response.notFound('Not found');
      });

      final handler = const shelf.Pipeline()
        .addMiddleware(shelf.logRequests())
        .addHandler(router.call);
      _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, int.parse(_port.text));
      setState(() => _status = 'HTTP server running on port ${_server!.port}');
    } catch (e) {
      _message('Could not start server: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stopServer() async {
    await _server?.close(force:true);
    _server = null;
    if (mounted) setState(() => _status = 'Server stopped');
  }

  Future<void> _connect() async {
    setState(() => _busy = true);
    try {
      final base = _clientUrl.text.trim().replaceAll(RegExp(r'/$'), '');
      final r = await _dio.post('$base/api/auth',
        data:{'password':_clientPassword.text},
        options:Options(contentType:Headers.jsonContentType));
      _token = r.data['token'] as String;
      await _refreshFiles();
      _message('Connected successfully.');
    } catch (e) { _message('Connection failed: $e'); }
    finally { if (mounted) setState(()=>_busy=false); }
  }

  Future<void> _refreshFiles() async {
    final base = _clientUrl.text.trim().replaceAll(RegExp(r'/$'), '');
    final r = await _dio.get('$base/api/files',
      options:Options(headers:{'Authorization':'Bearer $_token'}));
    setState(() => _files = List<Map<String,dynamic>>.from(r.data));
  }

  Future<void> _upload() async {
    final result = await FilePicker.platform.pickFiles(withData:true);
    if (result == null) return;
    final f = result.files.single;
    final bytes = f.bytes ?? (f.path != null ? await File(f.path!).readAsBytes() : null);
    if (bytes == null) { _message('Unable to read selected file.'); return; }
    try {
      final base = _clientUrl.text.trim().replaceAll(RegExp(r'/$'), '');
      await _dio.post('$base/api/upload?name=${Uri.encodeComponent(f.name)}',
        data:Stream.fromIterable([bytes]),
        options:Options(headers:{'Authorization':'Bearer $_token',
          Headers.contentLengthHeader:bytes.length},
          contentType:'application/octet-stream'));
      await _refreshFiles();
      _message('Upload complete.');
    } catch(e) { _message('Upload failed: $e'); }
  }

  Future<void> _download(String name) async {
    try {
      final base = _clientUrl.text.trim().replaceAll(RegExp(r'/$'), '');
      final r = await _dio.get<List<int>>('$base/api/download?name=${Uri.encodeComponent(name)}',
        options:Options(responseType:ResponseType.bytes,
          headers:{'Authorization':'Bearer $_token'}));
      final dir = await getApplicationDocumentsDirectory();
      await File('${dir.path}/$name').writeAsBytes(r.data!);
      _message('Saved to app Documents: ${dir.path}/$name');
    } catch(e) { _message('Download failed: $e'); }
  }

  void _message(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(s)));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('LAN File Server'), actions:[
      IconButton(onPressed:_chooseFolder, icon:const Icon(Icons.folder_open))
    ]),
    body: ListView(padding:const EdgeInsets.all(16), children:[
      Card(child:Padding(padding:const EdgeInsets.all(16), child:Column(
        crossAxisAlignment:CrossAxisAlignment.start, children:[
          const Text('SERVER MODE', style:TextStyle(fontWeight:FontWeight.bold)),
          const SizedBox(height:8),
          Text(_status),
          const SizedBox(height:8),
          TextField(controller:_password, obscureText:true,
            decoration:const InputDecoration(labelText:'Server password (min. 8 characters)')),
          TextField(controller:_port, keyboardType:TextInputType.number,
            decoration:const InputDecoration(labelText:'HTTP port')),
          const SizedBox(height:12),
          Wrap(spacing:8, children:[
            FilledButton(onPressed:_busy || _server != null ? null : _startServer,
              child:const Text('Start HTTP server')),
            OutlinedButton(onPressed:_server == null ? null : _stopServer,
              child:const Text('Stop server')),
          ]),
          const Text('Shared folder: app-private Documents directory',
            style:TextStyle(fontSize:12,color:Colors.grey)),
        ]))),
      const SizedBox(height:12),
      Card(child:Padding(padding:const EdgeInsets.all(16), child:Column(
        crossAxisAlignment:CrossAxisAlignment.start, children:[
          const Text('CLIENT MODE', style:TextStyle(fontWeight:FontWeight.bold)),
          TextField(controller:_clientUrl,
            decoration:const InputDecoration(labelText:'Server URL',
              hintText:'http://192.168.x.x:8080')),
          TextField(controller:_clientPassword, obscureText:true,
            decoration:const InputDecoration(labelText:'Server password')),
          const SizedBox(height:12),
          Wrap(spacing:8, children:[
            FilledButton(onPressed:_busy ? null : _connect, child:const Text('Connect')),
            OutlinedButton(onPressed:_token == null ? null : _refreshFiles,
              child:const Text('Refresh')),
            OutlinedButton(onPressed:_token == null ? null : _upload,
              child:const Text('Upload file')),
          ]),
        ]))),
      const SizedBox(height:12),
      Text('REMOTE FILES (${_files.length})',
        style:const TextStyle(fontWeight:FontWeight.bold)),
      ..._files.map((f)=>ListTile(
        leading:Icon(f['directory']==true ? Icons.folder : Icons.insert_drive_file),
        title:Text(f['name'].toString()),
        subtitle:Text(f['directory']==true ? 'Folder' : '${f['size']} bytes'),
        trailing:f['directory']==true ? null : IconButton(
          icon:const Icon(Icons.download),
          onPressed:()=>_download(f['name'].toString())),
      )),
      const SizedBox(height:16),
      const Text('Network note: connect both devices to the same Wi-Fi/hotspot. On iPhone, enable Personal Hotspot manually in Settings. Find the server phone IP in Wi-Fi/network settings.',
        style:TextStyle(fontSize:12,color:Colors.grey)),
    ]),
  );
}
