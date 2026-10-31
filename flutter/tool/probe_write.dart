import 'dart:io';

void main() {
  final targets = <String>[
    r'C:\Users\noaha\probe_home.txt',
    r'C:\Users\noaha\AppData\Roaming\probe_roaming.txt',
    r'C:\Users\noaha\AppData\Roaming\Lexumo\probe_lexumo.txt',
    r'C:\Users\noaha\AppData\Local\probe_local.txt',
    r'C:\Users\noaha\prj\lingueez-web\probe_ws.txt',
  ];
  for (final t in targets) {
    try {
      File(t).writeAsStringSync('x');
      print('OK    $t');
    } catch (e) {
      final s = '$e';
      print('DENY  $t  -> ${s.split('(OS Error').first}');
    }
  }
}
