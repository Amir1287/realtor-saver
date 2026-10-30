import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Realtor Saver',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        builder: (c, w) => Directionality(textDirection: TextDirection.rtl, child: w!),
        home: const Home(),
      );
}

const _ua = 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

// Extracts: name, biography, profile photo from the realtor page.
const _js = r'''
(function(){
  function q(sel,root){return (root||document).querySelector(sel);}
  function t(sel,root){var e=q(sel,root);return e?(e.innerText||e.textContent||'').replace(/\s+/g,' ').trim():'';}
  var bt=((document.title||'')+' '+(document.body?document.body.innerText:'')).toLowerCase().slice(0,3000);
  var blocked=/security verification|v.rification de s.curit.|just a moment|verify you are human|checking your browser|performing security/.test(bt);
  var card=q('#realtorDetailsCard');
  if(blocked||!card){return JSON.stringify({blocked:blocked,hasCard:!!card,name:'',bio:'',photo:''});}
  var name=t('.realtorCardName h1',card);
  var pos=t('.realtorCardTitle',card)||t('.realtorCardCorpName',card);
  var addr=t('.realtorCardAddress',card);
  if(!addr){
    var tl=card.querySelector('a[href^="tel:"]');
    if(tl){addr=tl.getAttribute('href').replace('tel:','').trim();}
  }
  var imgEl=q('img.realtorCardImage',card);
  var photo=imgEl?(imgEl.currentSrc||imgEl.src):'';
  var lines=[];
  if(pos)lines.push(pos);
  if(addr)lines.push(addr);
  return JSON.stringify({blocked:false,hasCard:true,name:name,bio:lines.join('\n').trim(),photo:photo});
})()
''';



class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final ctrl = TextEditingController();
  late final WebViewController wc;
  List<Map<String, dynamic>> history = [];
  bool busy = false;
  String status = '';
  String? savePath;
  bool verifying = false;
  Completer<String>? _imgWait;

  @override
  void initState() {
    super.initState();
    wc = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_ua)
      ..addJavaScriptChannel('ImgChannel', onMessageReceived: (m) {
        if (!(_imgWait?.isCompleted ?? true)) _imgWait!.complete(m.message);
      });
    _loadHistory();
    _loadSettings();
  }

  Future<File> _file(String n) async =>
      File('${(await getApplicationDocumentsDirectory()).path}/$n');

  Future<void> _loadSettings() async {
    final f = await _file('settings.json');
    if (await f.exists()) {
      final m = jsonDecode(await f.readAsString());
      setState(() => savePath = m['savePath']);
    }
  }

  Future<void> pickFolder() async {
    await Permission.manageExternalStorage.request();
    final p = await FilePicker.platform.getDirectoryPath();
    if (p == null) return;
    await (await _file('settings.json')).writeAsString(jsonEncode({'savePath': p}));
    setState(() {
      savePath = p;
      status = 'پوشه‌ی ذخیره: $p';
    });
  }

  Future<void> _loadHistory() async {
    final f = await _file('history.json');
    if (await f.exists()) {
      final l = jsonDecode(await f.readAsString()) as List;
      setState(() => history = l.cast<Map<String, dynamic>>());
    }
  }

  Future<void> _saveHistory() async =>
      (await _file('history.json')).writeAsString(jsonEncode(history));

  String _idOf(String url) =>
      RegExp(r'/agent/(\d+)').firstMatch(url)?.group(1) ?? url.split('?').first;

  String _safe(String s) => s.replaceAll(RegExp(r'[\\/:*?"<>|\n\r]'), ' ').trim();

  Future<Map<String, dynamic>?> _extract() async {
    try {
      final r = await wc.runJavaScriptReturningResult(_js);
      var s = r.toString();
      if (s.startsWith('"')) s = jsonDecode(s) as String;
      return jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // Folder: <name>/ with "<name> text.txt" and photo
  Future<bool> _writeFiles(Map<String, dynamic> e) async {
    final basePath = savePath ??
        ((await getExternalStorageDirectory()) ??
                await getApplicationDocumentsDirectory())
            .path;
    final dir = Directory('$basePath/${_safe(e['name'])}');
    await dir.create(recursive: true);
    final info = StringBuffer()
      ..write('${e['name']}\r\n${(e['info'] ?? '').toString().replaceAll('\n', '\r\n')}');
    // UTF-8 with BOM so Windows Notepad shows all characters correctly
    await File('${dir.path}/text.txt')
        .writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(info.toString())]);
    final img = (e['photo'] ?? '').toString();
    if (img.isEmpty) return false;
    final uri = Uri.parse((e['url'] ?? 'https://www.realtor.ca').toString()).resolve(img);
    final ext = (RegExp(r'\.(png|webp|jpe?g)(\?|$)', caseSensitive: false)
                .firstMatch(uri.toString())
                ?.group(1) ??
            'jpg')
        .toLowerCase();
    final out = File('${dir.path}/photo.$ext');
    // Attempt 1: direct HTTP download
    try {
      final c = HttpClient();
      final req = await c.getUrl(uri);
      req.headers.set('User-Agent', _ua);
      req.headers.set('Referer', 'https://www.realtor.ca/');
      req.headers.set('Accept', 'image/avif,image/webp,image/*,*/*;q=0.8');
      final res = await req.close();
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
      c.close();
      if (bytes.length < 500) throw Exception('small');
      await out.writeAsBytes(bytes);
      return true;
    } catch (_) {}
    // Attempt 2: download inside the WebView (same browser session)
    try {
      _imgWait = Completer<String>();
      await wc.runJavaScript("""
        fetch('${uri.toString()}').then(function(r){return r.blob();}).then(function(b){
          var fr=new FileReader();
          fr.onload=function(){ImgChannel.postMessage(fr.result);};
          fr.readAsDataURL(b);
        }).catch(function(e){ImgChannel.postMessage('ERR:'+e);});
      """);
      final data = await _imgWait!.future.timeout(const Duration(seconds: 25));
      if (data.startsWith('data:')) {
        final bytes = base64Decode(data.split(',').last);
        if (bytes.length > 500) {
          await out.writeAsBytes(bytes);
          return true;
        }
      }
    } catch (_) {}
    // Attempt 3: draw the on-page <img> onto a canvas
    try {
      _imgWait = Completer<String>();
      await wc.runJavaScript("""
        try{
          var im=document.querySelector('img.realtorCardImage');
          var c=document.createElement('canvas');
          c.width=im.naturalWidth;c.height=im.naturalHeight;
          c.getContext('2d').drawImage(im,0,0);
          ImgChannel.postMessage(c.toDataURL('image/jpeg',0.92));
        }catch(e){ImgChannel.postMessage('ERR:'+e);}
      """);
      final data = await _imgWait!.future.timeout(const Duration(seconds: 10));
      if (data.startsWith('data:')) {
        final bytes = base64Decode(data.split(',').last);
        if (bytes.length > 500) {
          await File('${dir.path}/photo.jpg').writeAsBytes(bytes);
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  Future<void> process() async {
    final m = RegExp(r'https?://\S+').firstMatch(ctrl.text);
    if (m == null) return setState(() => status = 'لینک معتبر پیدا نشد');
    final url = m.group(0)!;
    final id = _idOf(url);
    final dup = history.where((e) => e['id'] == id);
    if (dup.isNotEmpty) {
      return setState(() => status = '⚠️ لینک تکراری است (${dup.first['name']})');
    }
    setState(() {
      busy = true;
      status = 'در حال باز کردن صفحه...';
    });
    await wc.loadRequest(Uri.parse(url));
    Map<String, dynamic>? d;
    var loadSecs = 0;
    for (var i = 0; i < 240; i++) {
      await Future.delayed(const Duration(seconds: 1));
      try {
        await wc.runJavaScript('window.scrollTo(0, document.body.scrollHeight/2)');
      } catch (_) {}
      final r = await _extract();
      if (r == null) continue;
      if (r['blocked'] == true) {
        // Site shows "security verification": wait for the user to pass it
        loadSecs = 0;
        d = null;
        if (!verifying) {
          setState(() {
            verifying = true;
            status =
                '⚠️ سایت تأیید امنیتی خواسته. تو کادر پایین تیک «من ربات نیستم» رو بزن، بعدش خودکار ادامه میده.';
          });
        }
        continue;
      }
      if (verifying) {
        setState(() {
          verifying = false;
          status = 'در حال خواندن اطلاعات...';
        });
      }
      d = r;
      loadSecs++;
      final hasName = (r['name'] ?? '').toString().isNotEmpty;
      final hasPhoto = (r['photo'] ?? '').toString().isNotEmpty;
      final hasInfo = (r['bio'] ?? '').toString().isNotEmpty;
      if (hasName && hasPhoto && ((hasInfo && loadSecs >= 3) || loadSecs >= 8)) break;
      if (loadSecs >= 25) break;
    }
    verifying = false;
    final name = (d?['name'] ?? '').toString();
    if (d == null || name.isEmpty) {
      return setState(() {
        busy = false;
        status = 'نتونستم اطلاعات رو بخونم. دوباره امتحان کن.';
      });
    }
    var info = (d['bio'] ?? '').toString();
    final entry = {
      'id': id,
      'url': url,
      'name': name,
      'info': info,
      'photo': d['photo'] ?? '',
      'savedAt': DateTime.now().toIso8601String(),
    };
    final photoOk = await _writeFiles(entry);
    history.insert(0, entry);
    await _saveHistory();
    ctrl.clear();
    setState(() {
      busy = false;
      status = '✅ ذخیره شد: $name\n${info.isEmpty ? '⚠️ اطلاعات پیدا نشد\n' : ''}${photoOk ? '🖼 عکس ذخیره شد' : '⚠️ عکس دانلود نشد'}';
    });
  }

  // ---------- Excel backup ----------
  Future<void> exportBackup() async {
    final x = Excel.createExcel();
    final sh = x[x.getDefaultSheet()!];
    sh.appendRow(['ID', 'URL', 'Name', 'Information', 'Photo', 'SavedAt']
        .map((e) => TextCellValue(e))
        .toList());
    for (final e in history) {
      String c(k) {
        final s = (e[k] ?? '').toString();
        return s.length > 32000 ? s.substring(0, 32000) : s;
      }
      sh.appendRow(['id', 'url', 'name', 'info', 'photo', 'savedAt']
          .map((k) => TextCellValue(c(k)))
          .toList());
    }
    final bytes = x.encode();
    if (bytes == null) return;
    final d = await getTemporaryDirectory();
    final f = File('${d.path}/realtor_backup.xlsx');
    await f.writeAsBytes(bytes);
    await Share.shareXFiles([XFile(f.path)]);
  }

  Future<void> importBackup() async {
    final r = await FilePicker.platform
        .pickFiles(type: FileType.custom, allowedExtensions: ['xlsx']);
    if (r == null || r.files.single.path == null) return;
    try {
      setState(() {
        busy = true;
        status = 'در حال بازیابی...';
      });
      final x = Excel.decodeBytes(await File(r.files.single.path!).readAsBytes());
      final rows = x.tables.values.first.rows;
      var added = 0;
      for (final row in rows.skip(1)) {
        String v(int i) =>
            i < row.length ? (row[i]?.value?.toString() ?? '') : '';
        final e = {
          'id': v(0),
          'url': v(1),
          'name': v(2),
          'info': v(3),
          'photo': v(4),
          'savedAt': v(5),
        };
        if (e['id']!.isEmpty || history.any((h) => h['id'] == e['id'])) continue;
        history.add(e);
        await _writeFiles(e);
        added++;
      }
      await _saveHistory();
      setState(() {
        busy = false;
        status = '✅ $added مورد بازیابی شد';
      });
    } catch (_) {
      setState(() {
        busy = false;
        status = 'فایل اکسل معتبر نیست';
      });
    }
  }

  Future<void> saveDebug() async {
    final m = RegExp(r'https?://\S+').firstMatch(ctrl.text);
    if (m == null) return setState(() => status = 'اول لینک رو بچسبون');
    setState(() {
      busy = true;
      status = 'در حال گرفتن HTML صفحه (حدود ۲۰ ثانیه)...';
    });
    await wc.loadRequest(Uri.parse(m.group(0)!));
    for (var i = 0; i < 20; i++) {
      await Future.delayed(const Duration(seconds: 1));
      try {
        await wc.runJavaScript('window.scrollTo(0, document.body.scrollHeight/2)');
      } catch (_) {}
    }
    try {
      final r = await wc.runJavaScriptReturningResult('document.documentElement.outerHTML');
      var h = r.toString();
      if (h.startsWith('"')) h = jsonDecode(h) as String;
      final ex = await _extract();
      final d = await getTemporaryDirectory();
      final f = File('${d.path}/debug_page.html');
      await f.writeAsString('<!-- EXTRACTED: ${jsonEncode(ex)} -->\n$h');
      setState(() {
        busy = false;
        status = 'فایل آماده شد';
      });
      await Share.shareXFiles([XFile(f.path)]);
    } catch (_) {
      setState(() {
        busy = false;
        status = 'خطا در گرفتن HTML';
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('ذخیره‌ی ریلتور'), actions: [
          IconButton(
              onPressed: busy ? null : exportBackup,
              icon: const Icon(Icons.upload_file),
              tooltip: 'Export'),
          IconButton(
              onPressed: busy ? null : importBackup,
              icon: const Icon(Icons.download),
              tooltip: 'Import'),
        ]),
        body: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(children: [
            TextField(
              controller: ctrl,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(
                  border: OutlineInputBorder(), hintText: 'لینک رو اینجا بچسبون'),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                  onPressed: busy ? null : process,
                  child: busy
                      ? const SizedBox(
                          height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('بررسی و ذخیره')),
            ),
            OutlinedButton.icon(
              onPressed: pickFolder,
              icon: const Icon(Icons.folder_open),
              label: Text(savePath == null ? 'انتخاب پوشه‌ی ذخیره' : 'پوشه: $savePath',
                  overflow: TextOverflow.ellipsis),
            ),
            if (status.isNotEmpty)
              Padding(padding: const EdgeInsets.all(8), child: Text(status)),
            SizedBox(height: busy ? (verifying ? 400 : 260) : 1, child: WebViewWidget(controller: wc)),
            TextButton(onPressed: busy ? null : saveDebug, child: const Text('عیب‌یابی: ذخیره و ارسال HTML صفحه')),
            const Divider(),
            Text('تعداد ذخیره‌شده: ${history.length}'),
            Expanded(
              child: ListView(
                children: [
                  for (final e in history)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.person),
                      title: Text(e['name'] ?? ''),
                      subtitle: Text((e['savedAt'] ?? '').toString().split('T').first),
                    )
                ],
              ),
            ),
          ]),
        ),
      );
}
