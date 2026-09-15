import 'dart:convert';

/// 分转元，与 Node 版 fenToYuan 保持完全一致的输出
/// 整数返回 "5"，非整数返回 "3.5"
String fenToYuan(dynamic fen) {
  if (fen == null) return '0';
  final int? value = fen is int ? fen : int.tryParse(fen.toString());
  if (value == null || value == 0) return '0';
  final double yuan = value / 100;
  return yuan == yuan.floor() ? yuan.floor().toString() : yuan.toStringAsFixed(1);
}

class Coupon {
  const Coupon({
    required this.couponName,
    required this.discountAmount,
    required this.useCondition,
    required this.expireTime,
    required this.tabName,
  });

  final String couponName;
  final String discountAmount;
  final String useCondition;
  final String expireTime;
  final String tabName;

  /// 排序用的数值，解析失败按 0 处理
  double get amountValue => double.tryParse(discountAmount) ?? 0;

  /// 从美团 couponList 元素解析
  factory Coupon.fromApiJson(Map<String, dynamic> json) {
    final int? priceLimit =
        json['priceLimit'] is int ? json['priceLimit'] as int : int.tryParse('${json['priceLimit']}');

    String condition;
    if (priceLimit != null && priceLimit > 0) {
      condition = '满${fenToYuan(priceLimit)}元可用';
    } else {
      condition = (json['useCondition'] as String?)?.isNotEmpty == true
          ? json['useCondition'] as String
          : '无门槛';
    }

    final int? endTime =
        json['couponEndTime'] is int ? json['couponEndTime'] as int : int.tryParse('${json['couponEndTime']}');

    String expire;
    if (endTime != null && endTime > 0) {
      expire = DateTime.fromMillisecondsSinceEpoch(endTime).toIso8601String().split('T').first;
    } else {
      expire = (json['expireTime'] as String?)?.isNotEmpty == true
          ? json['expireTime'] as String
          : '长期有效';
    }

    return Coupon(
      couponName: (json['couponName'] as String?) ?? '',
      discountAmount: fenToYuan(json['couponValue'] ?? json['discountAmount']),
      useCondition: condition,
      expireTime: expire,
      tabName: (json['tabName'] as String?)?.isNotEmpty == true ? json['tabName'] as String : '其他',
    );
  }

  Map<String, dynamic> toJson() => {
        'couponName': couponName,
        'discountAmount': discountAmount,
        'useCondition': useCondition,
        'expireTime': expireTime,
        'tabName': tabName,
      };

  /// 金额从大到小排序
  static List<Coupon> sortByAmountDesc(List<Coupon> list) {
    final sorted = List<Coupon>.of(list);
    sorted.sort((a, b) => b.amountValue.compareTo(a.amountValue));
    return sorted;
  }
}

class MtAccount {
  const MtAccount({
    required this.alias,
    required this.token,
    this.deviceToken,
    required this.addedAt,
  });

  final String alias;
  final String token;
  final String? deviceToken;
  final int addedAt;

  Map<String, dynamic> toJson() => {
        'alias': alias,
        'token': token,
        'deviceToken': deviceToken,
        'addedAt': addedAt,
      };

  factory MtAccount.fromJson(Map<String, dynamic> json) => MtAccount(
        alias: json['alias'] as String,
        token: json['token'] as String,
        deviceToken: json['deviceToken'] as String?,
        addedAt: json['addedAt'] as int? ?? 0,
      );

  /// 用于日志与界面遮罩，避免完整 token 外泄
  String get maskedToken =>
      token.length > 8 ? '${token.substring(0, 8)}****' : '****';
}

/// 领券结果
class IssueResult {
  const IssueResult({
    required this.ok,
    this.coupons = const [],
    this.activityName = '',
    this.activityLink = '',
    this.code,
    this.error,
    this.message = '',
  });

  final bool ok;
  final List<Coupon> coupons;
  final String activityName;
  final String activityLink;
  final int? code;
  final String? error;
  final String message;

  int get count => coupons.length;

  /// 本次领取总额（元）
  double get totalAmount =>
      coupons.fold<double>(0, (sum, c) => sum + c.amountValue);
}

/// 从领券接口响应解析，统一处理错误码
IssueResult parseIssueResponse(Map<String, dynamic> data) {
  final int? code = data['code'] is int ? data['code'] as int : int.tryParse('${data['code']}');

  if (code == 200) {
    final Map<String, dynamic> payload =
        data['data'] is Map ? data['data'] as Map<String, dynamic> : const {};
    final List<dynamic> rawList = payload['couponList'] is List ? payload['couponList'] as List : const [];

    final coupons = rawList
        .whereType<Map<String, dynamic>>()
        .map(Coupon.fromApiJson)
        .toList();

    return IssueResult(
      ok: true,
      coupons: Coupon.sortByAmountDesc(coupons),
      activityName: (payload['activityName'] as String?) ?? '',
      activityLink: (payload['activityLink'] as String?) ?? '',
    );
  }

  const Map<int, List<String>> errorMap = {
    1014: ['ALREADY_RECEIVED', '今天已经领取过，每天限领一次。'],
    401: ['RE_LOGIN', '登录已失效，请重新授权。'],
    509: ['RATE_LIMIT', '请求频繁，系统保护中。'],
    50200: ['RATE_LIMIT', '请求频繁，系统保护中。'],
    9999: ['SYSTEM_ERROR', '系统异常，请稍后重试。'],
  };

  final entry = errorMap[code];
  final String apiMsg = (data['msg'] as String?)?.trim() ?? '';
  String displayMsg;

  if (code == 1014) {
    // 若服务端明确返回"发券失败"而非已领取，避免误导为已领过
    if (apiMsg.isNotEmpty && !apiMsg.contains('领') && !apiMsg.contains('已')) {
      displayMsg = '$apiMsg (错误码 1014: 安全校验或规则未通过)';
    } else {
      displayMsg = apiMsg.isNotEmpty ? apiMsg : (entry?[1] ?? '今天已经领取过，每天限领一次。');
    }
  } else {
    displayMsg = entry?[1] ?? (apiMsg.isNotEmpty ? apiMsg : '错误码 $code: 未知');
  }

  return IssueResult(
    ok: false,
    code: code,
    error: entry?[0] ?? 'UNKNOWN',
    message: displayMsg,
  );
}

/// 登录二维码请求结果
class AuthCodeResult {
  const AuthCodeResult({required this.ok, this.qrCodeUrl = '', this.message = ''});

  final bool ok;
  final String qrCodeUrl;
  final String message;

  factory AuthCodeResult.fromJson(Map<String, dynamic> json) => AuthCodeResult(
        ok: json['ok'] == true,
        qrCodeUrl: (json['qrCodeUrl'] as String?) ??
            (json['auth_link'] as String?) ??
            (json['shortUrl'] as String?) ??
            '',
        message: (json['message'] as String?) ?? '',
      );
}

/// 轮询 token 结果
class PollResult {
  const PollResult({required this.ok, this.token = '', this.deviceToken, this.message = ''});

  final bool ok;
  final String token;
  final String? deviceToken;
  final String message;

  factory PollResult.fromJson(Map<String, dynamic> json) => PollResult(
        ok: json['ok'] == true && (json['token'] as String?)?.isNotEmpty == true,
        token: (json['token'] as String?) ?? '',
        deviceToken: json['deviceToken'] as String?,
        message: (json['message'] as String?) ?? '',
      );
}

/// JSON 安全解析
Map<String, dynamic>? tryDecodeJson(String source) {
  try {
    final dynamic decoded = jsonDecode(source);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}
