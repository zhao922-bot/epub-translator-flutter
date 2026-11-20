import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/logging/app_logger.dart';
import '../../../../shared/platform/native_platform_bridge.dart';
import '../../../../shared/platform/platform_utils.dart';
import '../../../../shared/platform/windows_elevation_check.dart';
import '../../application/settings_controller.dart';
import 'settings_copy.dart';

class SettingsNotices extends ConsumerStatefulWidget {
  const SettingsNotices({super.key});

  @override
  ConsumerState<SettingsNotices> createState() => _SettingsNoticesState();
}

class _SettingsNoticesState extends ConsumerState<SettingsNotices> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final saveError = ref.read(settingsSaveErrorProvider);
      final conflict = ref.read(settingsWriteConflictProvider);
      if (saveError?.message != null || conflict != null) {
        final strings = ref.read(appStringsProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              saveError?.message != null
                  ? saveError!.settingsFileLocked
                        ? strings.settingsFileLocked(saveError.message!)
                        : strings.settingsSaveFailed
                  : strings.settingsConflictSnackBar,
            ),
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final controller = ref.read(settingsProvider.notifier);
    final secretKeyRotated = ref.watch(secretKeyRotatedNoticeProvider) != null;
    final writeConflict = ref.watch(settingsWriteConflictProvider) != null;
    final replayBlocked = ref.watch(settingsReplayBlockedProvider) != null;
    final replayInProgress = ref.watch(settingsReplayInProgressProvider);

    // Surface persistence failures (e.g. the secret store timing out): the
    // fields already show the new values, so warn instead of failing silently.
    // Repeated failures with the same message are merged into one notice —
    // without this a broken secret backend would fire a SnackBar per commit.
    ref.listen(settingsSaveErrorProvider, (previous, next) {
      if (next != null &&
          next.message != null &&
          next.message != previous?.message) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              next.settingsFileLocked
                  ? strings.settingsFileLocked(next.message ?? '')
                  : strings.settingsSaveFailed,
            ),
          ),
        );
      }
    });
    return Column(
      children: [
        // —— 安全提示 ——
        // Android KeyStore 密钥被轮换（锁屏/生物识别变更）：已保存的密钥
        // 已不可恢复，提醒用户重新输入。
        if (secretKeyRotated)
          _SettingsWarningBanner(text: strings.secretKeyRotatedWarning),
        // 跨实例写冲突：快照已过期，后续保存会继续冲突。提供"重新加载"
        // 恢复路径：重读磁盘文件后再保存即可通过。
        if (writeConflict)
          _SettingsWarningBanner(
            text: strings.isChinese
                ? '另一实例修改了设置，当前页面的值可能已过期，保存会失败。请重新加载后再试。'
                : 'Another instance changed the settings; this page may show stale values and saves will fail. Reload and try again.',
            actionLabel: strings.isChinese ? '重新加载' : 'Reload',
            onAction: () async {
              final eventId = ref.read(settingsWriteConflictProvider)?.id;
              final bool ok = await ref
                  .read(settingsProvider.notifier)
                  .reloadSettings();
              // P2-#38: keep the conflict notice when reload failed so
              // the user doesn't lose the recovery entry. P2-#39: the
              // page may be disposed while the reload is in flight.
              if (ok &&
                  mounted &&
                  ref.read(settingsWriteConflictProvider)?.id == eventId) {
                ref.read(settingsWriteConflictProvider.notifier).state = null;
              }
            },
          ),
        // 凭据回放被路由保护阻止：队列保留，等待用户确认为当前服务地址
        // 或放弃。无提示用户会不知晓凭据修改未生效。
        if (replayBlocked)
          _SettingsWarningBanner(
            text: strings.isChinese
                ? '有 ${controller.blockedReplayCount} 个凭据修改因服务地址变更被暂缓，等待确认。确认为当前地址后将继续保存，放弃则丢弃这些修改。'
                : '${controller.blockedReplayCount} credential change(s) are held back because the service address changed. Confirm to save them against the current address, or discard them.',
            actionLabel: strings.isChinese ? '确认应用' : 'Apply',
            onAction: replayInProgress
                ? null
                : () async {
                    if (controller.isReplayingConflictedEdits) return;
                    final eventId = ref.read(settingsReplayBlockedProvider)?.id;
                    await controller.confirmBlockedConflictReplays();
                    if (mounted &&
                        ref.read(settingsReplayBlockedProvider)?.id ==
                            eventId) {
                      ref.read(settingsReplayBlockedProvider.notifier).state =
                          null;
                    }
                  },
            secondaryActionLabel: strings.isChinese ? '放弃' : 'Discard',
            secondaryActionDisabled: replayInProgress,
            onSecondaryAction: () async {
              controller.discardBlockedConflictReplays();
              if (mounted) {
                ref.read(settingsReplayBlockedProvider.notifier).state = null;
              }
            },
          ),
        // Windows 提权运行：DPAPI 密钥与普通用户不互通，提醒用户。
        if (PlatformUtils.isWindows) const _WindowsElevatedWarning(),
      ],
    );
  }
}

/// Shows the Windows-elevation secret warning once the (cached, process-wide)
/// elevation check reports the process is elevated.
///
/// The widget owns a cancellable probe. Disposing it releases the timeout and
/// the child process, while a timeout settles the result and ignores late data.
class _WindowsElevatedWarning extends ConsumerStatefulWidget {
  const _WindowsElevatedWarning();

  @override
  ConsumerState<_WindowsElevatedWarning> createState() =>
      _WindowsElevatedWarningState();
}

class _WindowsElevatedWarningState
    extends ConsumerState<_WindowsElevatedWarning> {
  bool _elevated = false;
  late final WindowsElevationCheck _check;

  @override
  void initState() {
    super.initState();
    _check = NativePlatformBridge.startWindowsElevationCheck();
    unawaited(
      _check.result.then((bool elevated) {
        if (mounted) {
          setState(() {
            _elevated = elevated;
          });
        }
      }),
    );
  }

  @override
  void dispose() {
    _check.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_elevated) {
      return const SizedBox.shrink();
    }
    final AppStrings strings = ref.watch(appStringsProvider);
    return _SettingsWarningBanner(text: strings.windowsElevatedSecretWarning);
  }
}

/// Warning banner shown at the top of the settings page for secret-store
/// conditions the user must act on (Android KeyStore rotation, Windows
/// elevation, cross-instance write conflicts). Plain Card + icon so it fits
/// both light and dark themes. An optional action button (e.g. "Reload")
/// gives the user a recovery path without leaving the page.
class _SettingsWarningBanner extends StatelessWidget {
  const _SettingsWarningBanner({
    required this.text,
    this.actionLabel,
    this.onAction,
    this.secondaryActionLabel,
    this.onSecondaryAction,
    this.secondaryActionDisabled = false,
  });

  final String text;
  final String? actionLabel;
  final Future<void> Function()? onAction;
  final String? secondaryActionLabel;
  final Future<void> Function()? onSecondaryAction;
  final bool secondaryActionDisabled;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String? actionLabel = this.actionLabel;
    final Future<void> Function()? onAction = this.onAction;
    final String? secondaryActionLabel = this.secondaryActionLabel;
    final Future<void> Function()? onSecondaryAction = this.onSecondaryAction;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onErrorContainer,
                  ),
                ),
              ),
              if (secondaryActionLabel != null &&
                  onSecondaryAction != null) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: secondaryActionDisabled
                      ? null
                      : () {
                          // P2-#39: an unawaited banner action must not drop
                          // errors silently.
                          unawaited(
                            onSecondaryAction().then(
                              (_) {},
                              onError: (Object error) {
                                AppLogger.error(
                                  'Settings banner action failed: '
                                  '${error.runtimeType}',
                                  tag: 'settings',
                                );
                              },
                            ),
                          );
                        },
                  child: Text(secondaryActionLabel),
                ),
              ],
              if (actionLabel != null) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: onAction == null
                      ? null
                      : () {
                          // P2-#39: an unawaited banner action must not drop
                          // errors silently.
                          unawaited(
                            onAction().then(
                              (_) {},
                              onError: (Object error) {
                                AppLogger.error(
                                  'Settings banner action failed: '
                                  '${error.runtimeType}',
                                  tag: 'settings',
                                );
                              },
                            ),
                          );
                        },
                  child: Text(actionLabel),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
