import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as dcrypto;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_js/flutter_js.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/coupon_model.dart';

/// 美团鉴权、签名与领券统一核心服务
class MtCouponService {
  MtCouponService._();

  static JavascriptRuntime? _runtime;
  static bool _initialized = false;
  static Completer<void>? _initCompleter;

  static String? _cliguardInfoPath;
  static String _resolvedPackageName = 'com.nl.omniflow';

  static const String defaultAiScene = 'a0d4da77f918ab204d86c911fcdd0ce1';
  static const String clientId = 'c6f50b5a1e2f4e2bb00a3e2f58df3ced';
  static const String csecPlatform = '7';
  static const String csecVersion = '1.4.2';

  static const String userAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  static const String _codeApi =
      'https://passport.meituan.com/api/account/userauth/code';
  static const String _checkApi =
      'https://passport.meituan.com/api/account/userauth/check';
  static const String _couponUrl =
      'https://media.meituan.com/fulishemini/couponActivity/sendCouponWork';

  /// 设备指纹持久化 key
  static const String prefsKeyDfpid = 'mt_dfpid_info';

  // 登录临时状态
  static String _pkceVerifier = '';
  static String _authCode = '';
  static bool _isLoginCancelled = false;

  static bool get isReady => _initialized && _runtime != null;

  /// 惰性安全初始化 QuickJS 运行环境与签名库
  static Future<void> ensureInitialized() async {
    if (_initialized && _runtime != null) return;
    if (_initCompleter != null) return _initCompleter!.future;

    _initCompleter = Completer<void>();
    try {
      try {
        final info = await PackageInfo.fromPlatform();
        if (info.packageName.isNotEmpty) {
          _resolvedPackageName = info.packageName;
        }
      } catch (_) {}

      _runtime = getJavascriptRuntime();
      final home = '/data/user/0/$_resolvedPackageName';
      _runtime!.evaluate(
          'globalThis.__packageName = ${jsonEncode(_resolvedPackageName)}; globalThis.__homedir = ${jsonEncode(home)};');

      // 1. 加载 node_shim（已内联 buffer / crypto-js / base64-js / ieee754）
      _runtime!.evaluate(await rootBundle.loadString('assets/js/node_shim.js'));

      // 2. 加载 pako（gzip）
      _evalCjs(await rootBundle.loadString('assets/js/pako.min.js'));
      _runtime!.evaluate('globalThis.__pako = globalThis.exports;');

      // 3. 注入已持久化的设备指纹
      await _injectDeviceFingerprint();

      // 4. 加载 cliguard 1.4.2 签名核心库
      _evalCjs(await rootBundle.loadString('assets/js/cliguard.js'));
      _runtime!.evaluate('globalThis.__cliguard = globalThis.module.exports;');
      _runtime!.evaluate(
          'globalThis.module={exports:{}};globalThis.exports=globalThis.module.exports;');

      // 5. 注册高频预编译签名函数，避免重复解析构造闭包
      _runtime!.evaluate('''
        globalThis.__addParams = function(url) {
          try {
            var rr = globalThis.__cliguard.addCommonParams(url);
            return (rr && rr.url) ? rr.url : url;
          } catch(e) { return url; }
        };
        globalThis.__sign = function(method, url, bodyHash) {
          try {
            var rr = globalThis.__cliguard.signRequest(method, url, bodyHash);
            return JSON.stringify(rr || {});
          } catch(e) { return '{}'; }
        };
      ''');

      _initialized = true;
      _initCompleter!.complete();
    } catch (e) {
      _initCompleter!.completeError(e);
      rethrow;
    } finally {
      _initCompleter = null;
    }
  }

  static void _evalCjs(String src) {
    _runtime!.evaluate(
        'globalThis.module={exports:{}};globalThis.exports=globalThis.module.exports;');
    _runtime!.evaluate(src);
  }

  // ── 签名逻辑 ──────────────────────────────────────────────────────────

  /// 生成带完整签名的请求头（自动保证初始化，带 mtgsig）
  static Future<Map<String, String>> buildHeaders(
    String url,
    String bodyStr, {
    String? token,
  }) async {
    await ensureInitialized();

    final bytes = utf8.encode(bodyStr);
    final slice = bytes.length > 16200 ? bytes.sublist(0, 16200) : bytes;
    final bodyHash = dcrypto.md5.convert(slice).toString();

    final signedUrl = _addCommonParams(url);
    final sigHeaders = _signRequest('GET', signedUrl, bodyHash);

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Content-Length': '${bytes.length}',
      'User-Agent': userAgent,
      'Cache-Control': 'no-cache',
      'Accept': 'application/json, */*',
    };
    headers.addAll(sigHeaders);
    if (token != null && token.isNotEmpty) {
      headers['token'] = token;
    }
    return headers;
  }

  static String _addCommonParams(String url) {
    final r = _runtime;
    if (r == null) return url;
    try {
      final res = r.evaluate('globalThis.__addParams(${jsonEncode(url)})');
      final v = res.stringResult.trim();
      return v.isEmpty ? url : v;
    } catch (_) {
      return url;
    }
  }

  static Map<String, String> _signRequest(
    String method,
    String url,
    String bodyHash,
  ) {
    final r = _runtime;
    if (r == null) return const {};
    try {
      final res = r.evaluate(
          'globalThis.__sign(${jsonEncode(method)}, ${jsonEncode(url)}, ${jsonEncode(bodyHash)})');
      final decoded = tryDecodeJson(res.stringResult);
      if (decoded == null) return const {};
      return decoded.map((k, v) => MapEntry(k, v?.toString() ?? ''));
    } catch (_) {
      return const {};
    }
  }

  // ── 扫码登录流程 ──────────────────────────────────────────────────────

  /// 第一步：生成登录二维码与授权链接
  static Future<AuthCodeResult> getAuthCode() async {
    try {
      await ensureInitialized();
      _isLoginCancelled = false;
      _pkceVerifier = _randomHex(32);
      final challenge =
          dcrypto.sha256.convert(utf8.encode(_pkceVerifier)).toString();

      final url = '$_codeApi'
          '?client_id=$clientId'
          '&code_challenge=$challenge'
          '&csecplatform=$csecPlatform'
          '&csecversion=$csecVersion';
      final headers = await buildHeaders(url, '');

      final res = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 20));

      final decoded = tryDecodeJson(res.body);
      final data = decoded?['data'];
      if (data is Map) {
        _authCode = (data['authCode'] as String?) ?? '';
        final link = (data['shortLink'] as String?) ?? '';
        if (link.isNotEmpty) {
          return AuthCodeResult(ok: true, qrCodeUrl: link);
        }
      }
      return AuthCodeResult(
        ok: false,
        message: decoded?['message'] as String? ?? '获取二维码失败',
      );
    } catch (e) {
      return AuthCodeResult(ok: false, message: '获取二维码失败：$e');
    }
  }

  /// 第二步：轮询扫码确认结果（支持实时取消）
  static Future<PollResult> pollToken({
    Duration timeout = const Duration(minutes: 5),
  }) async {
    _isLoginCancelled = false;
    final deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      if (_isLoginCancelled) {
        return const PollResult(ok: false, message: '已取消登录');
      }

      try {
        final url = '$_checkApi'
            '?client_id=$clientId'
            '&auth_code=$_authCode'
            '&code_verifier=$_pkceVerifier'
            '&csecplatform=$csecPlatform'
            '&csecversion=$csecVersion';
        final headers = await buildHeaders(url, '');

        final res = await http
            .get(Uri.parse(url), headers: headers)
            .timeout(const Duration(seconds: 15));

        final decoded = tryDecodeJson(res.body);
        final data = decoded?['data'];
        if (data is Map) {
          final status = data['authStatus'];
          final token = data['token'] as String?;
          if (token != null && token.isNotEmpty) {
            await _persistDeviceFingerprint();
            return PollResult(ok: true, token: token);
          }
          if (status != 1) {
            final token2 = data['accessToken'] as String? ??
                data['userToken'] as String?;
            if (token2 != null && token2.isNotEmpty) {
              await _persistDeviceFingerprint();
              return PollResult(ok: true, token: token2);
            }
          }
        }
      } catch (_) {
        // 网络抖动静默重试
      }

      if (_isLoginCancelled) {
        return const PollResult(ok: false, message: '已取消登录');
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    return const PollResult(ok: false, message: '等待扫码超时，请重新生成二维码');
  }

  /// 取消当前正在进行的登录轮询
  static void cancelLogin() {
    _isLoginCancelled = true;
  }

  // ── 外部应用 / 浏览器唤起 ─────────────────────────────────────────────

  /// 优先唤起美团 App 授权；若未安装或唤起失败，自动回退到系统浏览器打开
  static Future<bool> openAuthLink(String link) async {
    if (link.isEmpty) return false;

    // 1. 尝试美团 App 专属 Web 协议
    final meituanUri = Uri.parse(
        'imeituan://www.meituan.com/web?url=${Uri.encodeComponent(link)}');
    try {
      if (await canLaunchUrl(meituanUri)) {
        final launched = await launchUrl(
          meituanUri,
          mode: LaunchMode.externalNonBrowserApplication,
        );
        if (launched) return true;
      }
    } catch (_) {}

    // 2. 回退到系统默认浏览器
    return openInBrowser(link);
  }

  /// 使用系统浏览器打开链接
  static Future<bool> openInBrowser(String link) async {
    if (link.isEmpty) return false;
    try {
      final webUri = Uri.parse(link);
      if (await canLaunchUrl(webUri)) {
        return await launchUrl(webUri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
    return false;
  }

  // ── 领券业务 ──────────────────────────────────────────────────────────

  /// 领取优惠券
  static Future<IssueResult> issueCoupon(String token) async {
    try {
      final body = jsonEncode(<String, dynamic>{
        'token': token,
        'aiScene': defaultAiScene,
        'version': 2,
      });
      final headers =
          await buildHeaders(_couponUrl, body, token: token);

      final res = await http
          .post(Uri.parse(_couponUrl), headers: headers, body: body)
          .timeout(const Duration(seconds: 20));

      final decoded = tryDecodeJson(res.body);
      if (decoded == null) {
        return const IssueResult(ok: false, error: 'NETWORK', message: '响应解析失败');
      }
      return parseIssueResponse(decoded);
    } on TimeoutException {
      return const IssueResult(ok: false, error: 'TIMEOUT', message: '美团接口请求超时');
    } catch (e) {
      final msg = e.toString();
      return IssueResult(
        ok: false,
        error: msg.contains('TimeoutException') ? 'TIMEOUT' : 'NETWORK',
        message: '请求失败: $msg',
      );
    }
  }

  // ── 设备指纹（dfpid） ────────────────────────────────────────────────

  static String get _infoPath {
    if (_cliguardInfoPath != null) return _cliguardInfoPath!;
    final home = '/data/user/0/$_resolvedPackageName';
    _cliguardInfoPath = '$home/.cliguard/cliguard-info.json';
    return _cliguardInfoPath!;
  }

  static Future<void> _injectDeviceFingerprint() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKeyDfpid);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      _runtime!.evaluate(
          'globalThis.__mem[${jsonEncode(_infoPath)}] = ${jsonEncode(raw)};');
    } catch (_) {}
  }

  static Future<void> _persistDeviceFingerprint() async {
    try {
      final res = _runtime!.evaluate(
          'globalThis.__mem[${jsonEncode(_infoPath)}] || null');
      final raw = res.stringResult.trim();
      if (raw.isEmpty || raw == 'null') return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKeyDfpid, raw);
    } catch (_) {}
  }

  static Future<void> setDeviceFingerprintFromJson(String jsonSource) async {
    try {
      final decoded = jsonDecode(jsonSource);
      if (decoded is! Map<String, dynamic>) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKeyDfpid, jsonSource);
    } catch (_) {}
  }

  // ── 工具与生命周期 ────────────────────────────────────────────────────

  static String _randomHex(int bytes) {
    final rnd = Random.secure();
    final b = List<int>.generate(bytes, (_) => rnd.nextInt(256));
    return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<void> dispose() async {
    cancelLogin();
    _runtime?.dispose();
    _runtime = null;
    _initialized = false;
  }
}
