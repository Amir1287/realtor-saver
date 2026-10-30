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
  function meta(p){var e=document.querySelector('meta[property="'+p+'"],meta[name="'+p+'"]');return e?(e.content||''):'';}
  function txt(e){return (e.innerText||e.textContent||'').trim();}
  var ld={};
  [].slice.call(document.querySelectorAll('script[type="application/ld+json"]')).forEach(function(s){
    try{
      var j=JSON.parse(s.textContent);
      var arr=Array.isArray(j)?j:(j['@graph']||[j]);
      arr.forEach(function(o){
        var t=JSON.stringify(o['@type']||'');
        if(/Person|RealEstateAgent|Agent/i.test(t)&&!ld.name){ld=o;}
      });
    }catch(e){}
  });
  var h1=document.querySelector('h1');
  var name=(ld.name||'')||(h1?txt(h1):'')||meta('og:title');
  name=name.replace(/\s*[\|\-–].*REALTOR.*$/i,'').trim();

  // biography: longest text block among bio/about/description-like elements
  var bio='';
  var sel='[class*="bio" i],[id*="bio" i],[class*="about" i],[id*="about" i],[class*="description" i],[id*="description" i],[class*="profile" i]';
  [].slice.call(document.querySelectorAll(sel)).forEach(function(e){
    var t=txt(e);
    if(t.length>60&&t.length<6000&&t.length>bio.length&&t!==name){bio=t;}
  });
  if(!bio)bio=(ld.description||'')||meta('og:description')||meta('description');

  // profile photo
  var tokens=name.toLowerCase().split(/\s+/).filter(function(x){return x.length>2});
  var best='',bestScore=0;
  [].slice.call(document.images).forEach(function(i){
    var src=i.currentSrc||i.src||'';
    if(src.indexOf('http')!=0)return;
    if(/logo|icon|sprite|banner|placeholder|\.svg/i.test(src))return;
    var alt=(i.alt||'').toLowerCase();
    var cls=((i.className||'')+' '+(i.id||'')+' '+src).toLowerCase();
    var sc=0;
    tokens.forEach(function(t){if(alt.indexOf(t)>=0)sc+=5;});
    if(/agent|profile|headshot|photo|individual|avatar|portrait/.test(cls))sc+=3;
    var w=i.naturalWidth||i.width||0;
    if(w>=100)sc+=1;
    if(sc>bestScore){bestScore=sc;best=src;}
  });
  var photo=best||(typeof ld.image==='string'?ld.image:(ld.image&&ld.image.url)||'')||meta('og:image');

  var extra=[];
  [].slice.call(document.querySelectorAll('a[href^="tel:"]')).forEach(function(a){
    var v=a.getAttribute('href').replace('tel:','');if(extra.indexOf('Phone: '+v)<0)extra.push('Phone: '+v);});
  [].slice.call(document.querySelectorAll('a[href^="mailto:"]')).forEach(function(a){
    var v=a.getAttribute('href').replace('mailto:','').split('?')[0];if(extra.indexOf('Email: '+v)<0)extra.push('Email: '+v);});
  return JSON.stringify({name:name,bio:bio,photo:photo,extra:extra});
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

  @override
  void initState() {
    super.initState();
    wc = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_ua);
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
      ..write('Name\r\n${e['name']}\r\n\r\nInformation\r\n${(e['info'] ?? '').toString().replaceAll('\n', '\r\n')}');
    // UTF-8 with BOM so Windows Notepad shows all characters correctly
    await File('${dir.path}/text.txt')
        .writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(info.toString())]);
    final img = (e['photo'] ?? '').toString();
    if (img.isEmpty) return false;
    try {
      final uri = Uri.parse((e['url'] ?? 'https://www.realtor.ca').toString()).resolve(img);
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
      final m = RegExp(r'\.(png|webp|jpe?g)(\?|$)', caseSensitive: false).firstMatch(uri.toString());
      final ext = (m?.group(1) ?? 'jpg').toLowerCase();
      await File('${dir.path}/photo.$ext').writeAsBytes(bytes);
      return true;
    } catch (_) {
      return false;
    }
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
    for (var i = 0; i < 25; i++) {
      await Future.delayed(const Duration(seconds: 1));
      try {
        await wc.runJavaScript('window.scrollTo(0, document.body.scrollHeight/2)');
      } catch (_) {}
      d = await _extract() ?? d;
      final ok = (d?['name'] ?? '').toString().isNotEmpty;
      final full = ok &&
          (d?['bio'] ?? '').toString().isNotEmpty &&
          (d?['photo'] ?? '').toString().isNotEmpty;
      if (full || (ok && i >= 12)) break;
    }
    final name = (d?['name'] ?? '').toString();
    if (d == null || name.isEmpty) {
      return setState(() {
        busy = false;
        status = 'نتونستم اطلاعات رو بخونم. دوباره امتحان کن.';
      });
    }
    var info = (d['bio'] ?? '').toString();
    final extra = (d['extra'] as List?)?.join('\n') ?? '';
    if (extra.isNotEmpty) info = info.isEmpty ? extra : '$info\n\n$extra';
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
            SizedBox(height: busy ? 280 : 1, child: WebViewWidget(controller: wc)),
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
