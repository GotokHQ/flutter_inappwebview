import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview_internal_annotations/flutter_inappwebview_internal_annotations.dart';
import '../in_app_webview/platform_webview.dart';
part 'navigation_action_policy.g.dart';

///Class that is used by [PlatformWebViewCreationParams.shouldOverrideUrlLoading] event.
///It represents the policy to pass back to the decision handler.
@ExchangeableEnum()
class NavigationActionPolicy_ {
  // ignore: unused_field
  final int _value;
  const NavigationActionPolicy_._internal(this._value);

  ///Cancel the navigation.
  static const CANCEL = const NavigationActionPolicy_._internal(0);

  ///Allow the navigation to continue.
  static const ALLOW = const NavigationActionPolicy_._internal(1);

  ///Turn the navigation into a download.
  ///
  ///**NOTE**: available only on iOS 14.5+. It will fallback to [CANCEL].
  static const DOWNLOAD = const NavigationActionPolicy_._internal(2);

  ///GOTOK FORK: Allow the navigation to continue, but without letting WebKit
  ///try to open the URL as a Universal Link / app link. On iOS/macOS this maps
  ///to the stable WebKit policy `_WKNavigationActionPolicyAllowWithoutTryingAppLink`
  ///(`WKNavigationActionPolicy.allow + 2`), which is what full browsers (Firefox,
  ///Brave) use to keep navigation in the webview instead of launching the
  ///installed native app. On all other platforms it falls back to [ALLOW].
  static const ALLOW_WITHOUT_TRYING_APP_LINK =
      const NavigationActionPolicy_._internal(3);
}
