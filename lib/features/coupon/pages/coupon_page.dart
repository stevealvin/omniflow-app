import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/coupon_model.dart';
import '../services/mt_account_store.dart';
import '../services/mt_coupon_service.dart';

/// 美团领券助手主页面
class CouponPage extends StatefulWidget {
  const CouponPage({super.key});

  @override
  State<CouponPage> createState() => _CouponPageState();
}

enum _Phase { idle, working, qrcode, polling, done }

class _CouponPageState extends State<CouponPage> {
  _Phase _phase = _Phase.idle;
  String _qrUrl = '';
  IssueResult? _result;
  String _statusText = '';
  String _errorText = '';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    MtCouponService.cancelLogin();
    super.dispose();
  }

  Future<void> _boot() async {
    await MtAccountStore.init();
    if (!mounted) return;
    setState(() {});
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  // ── 登录流程 ──────────────────────────────────────────────────────────

  Future<void> _startLogin() async {
    setState(() {
      _phase = _Phase.working;
      _errorText = '';
      _statusText = '正在获取登录授权…';
    });

    final code = await MtCouponService.getAuthCode();
    if (!mounted) return;

    if (!code.ok || code.qrCodeUrl.isEmpty) {
      setState(() {
        _phase = _Phase.idle;
        _errorText = code.message.isNotEmpty ? code.message : '获取授权码失败';
        _statusText = '';
      });
      return;
    }

    setState(() {
      _phase = _Phase.qrcode;
      _qrUrl = code.qrCodeUrl;
      _statusText = '';
    });

    await _pollForToken();
  }

  Future<void> _pollForToken() async {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.polling;
      _statusText = '等待美团授权确认中…';
    });

    final poll =
        await MtCouponService.pollToken(timeout: const Duration(minutes: 5));

    if (!mounted) return;

    if (!poll.ok || poll.token.isEmpty) {
      // 若是用户主动取消，则保持静默不报错
      if (poll.message.contains('取消')) {
        setState(() {
          _phase = _Phase.idle;
          _statusText = '';
          _qrUrl = '';
        });
        return;
      }

      setState(() {
        _phase = _Phase.idle;
        _errorText = poll.message.isNotEmpty ? poll.message : '未获取到有效凭据';
        _statusText = '';
        _qrUrl = '';
      });
      return;
    }

    final alias = MtAccountStore.nextAlias();
    await MtAccountStore.saveAccount(MtAccount(
      alias: alias,
      token: poll.token,
      deviceToken: poll.deviceToken,
      addedAt: DateTime.now().millisecondsSinceEpoch,
    ));

    if (!mounted) return;
    setState(() {
      _phase = _Phase.idle;
      _statusText = '';
      _qrUrl = '';
    });
    _snack('账号「$alias」登录成功并已保存！');
  }

  void _cancelLogin() {
    MtCouponService.cancelLogin();
    setState(() {
      _phase = _Phase.idle;
      _qrUrl = '';
      _statusText = '';
    });
  }

  // ── 跳转与链接操作 ──────────────────────────────────────────────────

  Future<void> _openMeituanAuth() async {
    if (_qrUrl.isEmpty) return;
    _snack('正在尝试唤起美团 App…');
    final ok = await MtCouponService.openAuthLink(_qrUrl);
    if (!ok && mounted) {
      _snack('未能打开美团或浏览器，请使用扫码或复制链接');
    }
  }

  Future<void> _openBrowserAuth() async {
    if (_qrUrl.isEmpty) return;
    final ok = await MtCouponService.openInBrowser(_qrUrl);
    if (!ok && mounted) {
      _snack('未能唤起系统浏览器，请使用扫码或复制链接');
    }
  }

  void _copyLink() {
    if (_qrUrl.isEmpty) return;
    Clipboard.setData(ClipboardData(text: _qrUrl));
    _snack('授权链接已复制到剪贴板');
  }

  // ── 领券流程 ──────────────────────────────────────────────────────────

  Future<void> _claim() async {
    final account = MtAccountStore.active;
    if (account == null) {
      _snack('请先登录美团账号');
      return;
    }

    setState(() {
      _phase = _Phase.working;
      _errorText = '';
      _statusText = '正在极速领取优惠券…';
    });

    final result = await MtCouponService.issueCoupon(account.token);

    if (!mounted) return;
    setState(() {
      _phase = _Phase.done;
      _result = result;
      _statusText = '';
      if (!result.ok) {
        _errorText = result.message;
      }
    });
  }

  // ── 账号操作 ──────────────────────────────────────────────────────────

  Future<void> _switchAccount(String alias) async {
    await MtAccountStore.setActive(alias);
    if (!mounted) return;
    setState(() {
      _result = null;
      _errorText = '';
      _phase = _Phase.idle;
    });
  }

  Future<void> _deleteAccount(String alias) async {
    await MtAccountStore.deleteAccount(alias);
    if (!mounted) return;
    setState(() {
      _result = null;
      _errorText = '';
      _phase = _Phase.idle;
    });
    _snack('已删除账号「$alias」');
  }

  Future<void> _importDfpid() async {
    if (!mounted) return;
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入设备指纹（dfpid）'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '可将电脑端 ~/.cliguard/cliguard-info.json 的内容粘贴至下方，继承常用设备身份。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 4,
              minLines: 2,
              decoration: const InputDecoration(
                hintText: '{"localid":"...","dfpid":"..."}',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('导入'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    final raw = controller.text.trim();
    if (raw.isEmpty) {
      _snack('内容为空，未导入');
      return;
    }
    await MtCouponService.setDeviceFingerprintFromJson(raw);
    if (!mounted) return;
    _snack('设备指纹已保存，下次登录时自动生效');
  }

  // ── UI 布局 ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _buildAccountCard(cs),
          const SizedBox(height: 12),
          if (_errorText.isNotEmpty) ...[
            _buildErrorCard(cs),
            const SizedBox(height: 12),
          ],
          _buildActionCard(cs),
          if (_result != null && _result!.ok) ...[
            const SizedBox(height: 18),
            _buildCouponList(cs),
          ],
        ],
      ),
    );
  }

  Widget _buildAccountCard(ColorScheme cs) {
    return ValueListenableBuilder<List<MtAccount>>(
      valueListenable: MtAccountStore.accountsNotifier,
      builder: (context, accounts, _) {
        if (accounts.isEmpty) {
          return _card(
            cs,
            child: Row(
              children: [
                Icon(LucideIcons.userRoundPlus, size: 20, color: cs.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '尚未登录美团账号',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '点击下方按钮扫码或跳转美团授权登录',
                        style: TextStyle(
                            fontSize: 12, color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        return ValueListenableBuilder<String?>(
          valueListenable: MtAccountStore.activeAliasNotifier,
          builder: (context, activeAlias, _) {
            final active = MtAccountStore.active;
            return _card(
              cs,
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: cs.primaryContainer.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(LucideIcons.userRound,
                        size: 20, color: cs.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          active?.alias ?? '未选择账号',
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          active?.maskedToken ?? '请选择激活账号',
                          style: TextStyle(
                              fontSize: 11, color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '账号管理',
                    icon: Icon(LucideIcons.settings2,
                        size: 19, color: cs.onSurfaceVariant),
                    onSelected: (val) {
                      if (val == '__delete__' && active != null) {
                        _deleteAccount(active.alias);
                      } else if (val == '__import_dfpid__') {
                        _importDfpid();
                      } else {
                        _switchAccount(val);
                      }
                    },
                    itemBuilder: (ctx) => [
                      for (final a in accounts)
                        PopupMenuItem<String>(
                          value: a.alias,
                          child: Row(
                            children: [
                              if (a.alias == activeAlias)
                                Icon(LucideIcons.check,
                                    size: 16, color: cs.primary)
                              else
                                const SizedBox(width: 16),
                              const SizedBox(width: 6),
                              Text(a.alias),
                            ],
                          ),
                        ),
                      const PopupMenuDivider(),
                      const PopupMenuItem<String>(
                        value: '__import_dfpid__',
                        child: Row(
                          children: [
                            Icon(LucideIcons.fingerprint, size: 16),
                            SizedBox(width: 8),
                            Text('导入设备指纹（dfpid）'),
                          ],
                        ),
                      ),
                      const PopupMenuItem<String>(
                        value: '__delete__',
                        child: Row(
                          children: [
                            Icon(LucideIcons.trash2,
                                size: 16, color: Colors.redAccent),
                            SizedBox(width: 8),
                            Text('删除当前账号',
                                style: TextStyle(color: Colors.redAccent)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildErrorCard(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: cs.errorContainer.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.circleAlert, size: 16, color: cs.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _errorText,
              style: TextStyle(
                  fontSize: 12,
                  color: cs.onErrorContainer,
                  fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionCard(ColorScheme cs) {
    final hasAccount = MtAccountStore.hasAccount;
    final isBusy = _phase == _Phase.working || _phase == _Phase.polling;

    return _card(
      cs,
      child: Column(
        children: [
          if (_phase == _Phase.qrcode || _phase == _Phase.polling) ...[
            // ── 二维码与链接展示模式 ──
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(LucideIcons.scanLine, size: 16, color: cs.primary),
                const SizedBox(width: 6),
                Text(
                  '美团授权登录',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: cs.onSurface),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 二维码区域
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: QrImageView(
                data: _qrUrl,
                version: QrVersions.auto,
                size: 170,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 12),

            // 链接展示与快捷复制栏
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(LucideIcons.link,
                      size: 14, color: cs.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _qrUrl,
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                        fontFamily: 'monospace',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: _copyLink,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      child: Row(
                        children: [
                          Icon(LucideIcons.copy,
                              size: 13, color: cs.primary),
                          const SizedBox(width: 3),
                          Text(
                            '复制',
                            style: TextStyle(
                                fontSize: 11,
                                color: cs.primary,
                                fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // 操作按钮组：优先美团打开，次选浏览器打开
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _openMeituanAuth,
                    icon: const Icon(LucideIcons.externalLink, size: 16),
                    label: const Text('打开美团授权'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFFFC300),
                      foregroundColor: const Color(0xFF222222),
                      textStyle: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: _openBrowserAuth,
                  icon: const Icon(LucideIcons.globe, size: 15),
                  label: const Text('浏览器打开'),
                ),
              ],
            ),
            const SizedBox(height: 10),

            if (_statusText.isNotEmpty)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: cs.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _statusText,
                    style: TextStyle(fontSize: 12, color: cs.primary),
                  ),
                ],
              ),
            const SizedBox(height: 8),

            TextButton.icon(
              onPressed: _cancelLogin,
              icon: const Icon(LucideIcons.x, size: 15),
              label: const Text('取消本次登录'),
            ),
          ] else ...[
            // ── 默认操作按钮模式 ──
            SizedBox(
              width: double.infinity,
              height: 46,
              child: FilledButton.icon(
                onPressed: isBusy ? null : (hasAccount ? _claim : _startLogin),
                icon: isBusy
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: cs.onPrimary,
                        ),
                      )
                    : Icon(hasAccount
                        ? LucideIcons.ticket
                        : LucideIcons.scanQrCode),
                label: Text(
                  hasAccount
                      ? (_phase == _Phase.working ? '正在极速领券…' : '立即领券')
                      : '扫码 / 跳转登录美团账号',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            if (_statusText.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                _statusText,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ],
            if (hasAccount) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: isBusy ? null : _startLogin,
                icon: const Icon(LucideIcons.userRoundPlus, size: 15),
                label: const Text('添加或切换其他账号'),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildCouponList(ColorScheme cs) {
    final result = _result!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(LucideIcons.ticketCheck, size: 18, color: cs.primary),
            const SizedBox(width: 8),
            Text(
              '本次成功领取 ${result.count} 张优惠券',
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            Text(
              '合计 ¥${result.totalAmount.toStringAsFixed(result.totalAmount == result.totalAmount.roundToDouble() ? 0 : 1)}',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: cs.primary),
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (final coupon in result.coupons)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _buildCouponItem(cs, coupon),
          ),
      ],
    );
  }

  Widget _buildCouponItem(ColorScheme cs, Coupon coupon) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Column(
              children: [
                Text(
                  '¥${coupon.discountAmount}',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: cs.primary,
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    coupon.tabName,
                    style: TextStyle(
                        fontSize: 10,
                        color: cs.primary,
                        fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  coupon.couponName,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(LucideIcons.tag,
                        size: 11, color: cs.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        coupon.useCondition,
                        style: TextStyle(
                            fontSize: 11, color: cs.onSurfaceVariant),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(LucideIcons.calendar,
                        size: 11, color: cs.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(
                      coupon.expireTime,
                      style: TextStyle(
                          fontSize: 11, color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(ColorScheme cs, {required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: child,
    );
  }
}
