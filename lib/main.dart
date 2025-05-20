import 'dart:convert';
import 'dart:io';
import 'package:bloc/bloc.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:appsflyer_sdk/appsflyer_sdk.dart';
import 'package:timezone/data/latest.dart' as tzData;
import 'package:timezone/timezone.dart' as tz;
import 'package:percent_indicator/percent_indicator.dart';

// ====================
// CONSTANTS
// ====================
const String APPSFLYER_DEV_KEY = "qsBLmy7dAXDQhowM8V3ca4";
const String APPSFLYER_APP_ID = "6746164027";
const String WEBVIEW_URL = "https://apig.selchick.digital";

// ====================
// MODEL
// ====================
class DeviceInfo {
  final String? deviceId;
  final String? instanceId;
  final String? osType;
  final String? osVersion;
  final String? appVersion;
  final String? language;
  final String? timezone;
  final bool pushEnabled;

  DeviceInfo({
    this.deviceId,
    this.instanceId,
    this.osType,
    this.osVersion,
    this.appVersion,
    this.language,
    this.timezone,
    this.pushEnabled = true,
  });

  Map<String, dynamic> toJson({String? fcmToken}) => {
    "fcm_token": fcmToken ?? 'no_fcm_token',
    "device_id": deviceId ?? 'no_device',
    "app_name": "selchick",
    "instance_id": instanceId ?? 'no_instance',
    "platform": osType ?? 'no_type',
    "os_version": osVersion ?? 'no_os',
    "app_version": appVersion ?? 'no_app',
    "language": language ?? 'en',
    "timezone": timezone ?? 'UTC',
    "push_enabled": pushEnabled,
  };
}

// ====================
// SERVICES
// ====================
class DeviceInfoService {
  Future<DeviceInfo> fetchDeviceInfo() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      String? deviceId, osType, osVersion;
      if (Platform.isAndroid) {
        final info = await deviceInfo.androidInfo;
        deviceId = info.id;
        osType = "android";
        osVersion = info.version.release;
      } else if (Platform.isIOS) {
        final info = await deviceInfo.iosInfo;
        deviceId = info.identifierForVendor;
        osType = "ios";
        osVersion = info.systemVersion;
      }
      final packageInfo = await PackageInfo.fromPlatform();
      String language = Platform.localeName.split('_')[0];
      String timezone = tz.local.name;
      return DeviceInfo(
        deviceId: deviceId,
        instanceId: "d67f-banana-1234-chimp",
        osType: osType,
        osVersion: osVersion,
        appVersion: packageInfo.version,
        language: language,
        timezone: timezone,
      );
    } catch (e, stack) {
      print("DeviceInfoService.fetchDeviceInfo error: $e\n$stack");
      // Вернуть пустой объект чтобы не было ошибок в остальном коде
      return DeviceInfo();
    }
  }
}

class TokenChannelService {
  static const MethodChannel _channel = MethodChannel('com.example.fcm/token');
  void listenToken(Function(String token) onToken) {
    try {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'setToken') {
          final String token = call.arguments as String;
          onToken(token);
        }
      });
    } catch (e, stack) {
      print("TokenChannelService.listenToken error: $e\n$stack");
    }
  }
}

class AppsFlyerService {
  final _options = AppsFlyerOptions(
    afDevKey: APPSFLYER_DEV_KEY,
    appId: APPSFLYER_APP_ID,
    showDebug: true,
  );

  AppsflyerSdk? _sdk;
  String _appsFlyerId = "";
  String _conversionData = "";

  Future<void> initialize(VoidCallback onUpdate) async {
    try {
      _sdk = AppsflyerSdk(_options);
      _sdk?.initSdk(
        registerConversionDataCallback: true,
        registerOnAppOpenAttributionCallback: true,
        registerOnDeepLinkingCallback: true,
      );
      _sdk?.startSDK(
        onSuccess: () => debugPrint("AppsFlyer started"),
        onError: (code, msg) => debugPrint("AppsFlyer error $code $msg"),
      );
      _sdk?.onInstallConversionData((result) {
        try {
          if (result == null) {
            _conversionData = "";
          } else {
            _conversionData = jsonEncode(result);
          }
        } catch (e, stack) {
          print("AppsFlyerService.onInstallConversionData error: $e\n$stack");
          _conversionData = result?.toString() ?? "";
        }
        onUpdate();
      });
      try {
        _appsFlyerId = await _sdk?.getAppsFlyerUID() ?? "";
      } catch (e, stack) {
        print("AppsFlyerService.getAppsFlyerUID error: $e\n$stack");
        _appsFlyerId = "";
      }
      onUpdate();
    } catch (e, stack) {
      print("AppsFlyerService.initialize error: $e\n$stack");
      _conversionData = "";
      onUpdate();
    }
  }

  String get appsFlyerId => _appsFlyerId;
  String get conversionData => _conversionData;
}

// ====================
// BLoC STATE AND EVENTS
// ====================
class SplashEvent {}

class SplashStarted extends SplashEvent {}

class SplashTokenReceived extends SplashEvent {
  final String token;
  SplashTokenReceived(this.token);
}

class SplashTimeout extends SplashEvent {}

class SplashState {
  final bool isLoading;
  final String? token;
  final double percent;

  SplashState({this.isLoading = true, this.token, this.percent = 0.7});

  SplashState copyWith({
    bool? isLoading,
    String? token,
    double? percent,
  }) =>
      SplashState(
        isLoading: isLoading ?? this.isLoading,
        token: token ?? this.token,
        percent: percent ?? this.percent,
      );
}

class SplashBloc extends Bloc<SplashEvent, SplashState> {
  final TokenChannelService tokenChannelService;

  bool _navigated = false;

  SplashBloc(this.tokenChannelService) : super(SplashState()) {
    on<SplashStarted>((event, emit) async {
      emit(state.copyWith(isLoading: true, percent: 0.7));

      try {
        tokenChannelService.listenToken((token) {
          if (!_navigated) {
            add(SplashTokenReceived(token));
          }
        });
      } catch (e, stack) {
        print("SplashBloc: ошибка при listenToken: $e\n$stack");
      }

      // Timeout fallback (если токен не пришёл через канал)
      Future.delayed(const Duration(seconds: 5), () {
        if (!_navigated) {
          add(SplashTimeout());
        }
      });
    });

    on<SplashTokenReceived>((event, emit) {
      if (!_navigated) {
        _navigated = true;
        emit(state.copyWith(isLoading: false, token: event.token, percent: 1.0));
      }
    });

    on<SplashTimeout>((event, emit) {
      if (!_navigated) {
        _navigated = true;
        emit(state.copyWith(isLoading: false, token: '', percent: 1.0));
      }
    });
  }
}

// ====================
// WEBVIEW BLoC
// ====================
class WebViewEvent {}

class WebViewInit extends WebViewEvent {}

class WebViewSetController extends WebViewEvent {
  final InAppWebViewController controller;
  WebViewSetController(this.controller);
}

class WebViewLoaded extends WebViewEvent {}

class WebViewState {
  final bool isLoading;
  final InAppWebViewController? controller;
  final DeviceInfo? deviceInfo;
  final String? appsFlyerId;
  final String? conversionData;
  final double percent;

  WebViewState({
    this.isLoading = true,
    this.controller,
    this.deviceInfo,
    this.appsFlyerId,
    this.conversionData,
    this.percent = 0.7,
  });

  WebViewState copyWith({
    bool? isLoading,
    InAppWebViewController? controller,
    DeviceInfo? deviceInfo,
    String? appsFlyerId,
    String? conversionData,
    double? percent,
  }) {
    // Все значения, которые могут быть null, заменяются на безопасные дефолты
    return WebViewState(
      isLoading: isLoading ?? this.isLoading,
      controller: controller ?? this.controller,
      deviceInfo: deviceInfo ?? this.deviceInfo ?? DeviceInfo(),
      appsFlyerId: appsFlyerId ?? this.appsFlyerId ?? "",
      conversionData: conversionData ?? this.conversionData ?? "",
      percent: percent ?? this.percent,
    );
  }
}

class WebViewBloc extends Bloc<WebViewEvent, WebViewState> {
  final DeviceInfoService deviceInfoService;
  final AppsFlyerService appsFlyerService;
  final String pushToken;

  WebViewBloc(this.deviceInfoService, this.appsFlyerService, this.pushToken)
      : super(WebViewState()) {
    on<WebViewInit>((event, emit) async {
      emit(state.copyWith(isLoading: true, percent: 0.7));
      DeviceInfo? deviceInfo;
      try {
        deviceInfo = await deviceInfoService.fetchDeviceInfo();
      } catch (e, stack) {
        print("WebViewBloc.WebViewInit: ошибка получения deviceInfo: $e\n$stack");
        deviceInfo = DeviceInfo();
      }

      try {
        await appsFlyerService.initialize(() {
          add(WebViewLoaded());
        });
      } catch (e, stack) {
        print("WebViewBloc.WebViewInit: ошибка инициализации AppsFlyer: $e\n$stack");
      }
      emit(state.copyWith(
        deviceInfo: deviceInfo ?? DeviceInfo(),
        appsFlyerId: appsFlyerService.appsFlyerId,
        conversionData: appsFlyerService.conversionData,
        isLoading: false,
        percent: 1.0,
      ));
    });

    on<WebViewSetController>((event, emit) {
      emit(state.copyWith(controller: event.controller));
    });

    on<WebViewLoaded>((event, emit) {
      emit(state.copyWith(
        appsFlyerId: appsFlyerService.appsFlyerId,
        conversionData: appsFlyerService.conversionData,
      ));
    });
  }

  Future<void> sendDeviceDataToWeb() async {
    if (state.controller != null && state.deviceInfo != null) {
      try {
        await state.controller?.evaluateJavascript(source: '''
          localStorage.setItem('app_data', JSON.stringify(${jsonEncode(state.deviceInfo!.toJson(fcmToken: pushToken))}));
        ''');
      } catch (e, stack) {
        print("WebViewBloc.sendDeviceDataToWeb error: $e\n$stack");
      }
    }
  }

  Future<void> sendRawDataToWeb() async {
    if (state.controller != null && state.deviceInfo != null) {
      final data = {
        "content": {
          "af_data": state.conversionData ?? "",
          "af_id": state.appsFlyerId ?? "",
          "fb_app_name": "selchick",
          "app_name": "selchick",
          "deep": null,
          "bundle_identifier": "com.ghiokiel.chickenchaos.chickenchaos",
          "app_version": "1.0.0",
          "apple_id": APPSFLYER_APP_ID,
          "fcm_token": pushToken,
          "device_id": state.deviceInfo?.deviceId ?? "no_device",
          "instance_id": state.deviceInfo?.instanceId ?? "no_instance",
          "platform": state.deviceInfo?.osType ?? "no_type",
          "os_version": state.deviceInfo?.osVersion ?? "no_os",
          "app_version": state.deviceInfo?.appVersion ?? "no_app",
          "language": state.deviceInfo?.language ?? "en",
          "timezone": state.deviceInfo?.timezone ?? "UTC",
          "push_enabled": state.deviceInfo?.pushEnabled,
          "useruid": state.appsFlyerId ?? "",
        },
      };
      final jsonString = jsonEncode(data);

      print("load JS $jsonString");
      try {
        await state.controller?.evaluateJavascript(
          source: "sendRawData(${jsonEncode(jsonString)});",
        );
      } catch (e, stack) {
        print("WebViewBloc.sendRawDataToWeb error: $e\n$stack");
      }
    }
  }
}

// ====================
// UI: MAIN
// ====================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
  } catch (e, stack) {
    print("main: Firebase.initializeApp error: $e\n$stack");
  }
  try {
    FirebaseMessaging.onBackgroundMessage(_backgroundHandler);
  } catch (e, stack) {
    print("main: FirebaseMessaging.onBackgroundMessage error: $e\n$stack");
  }

  if (Platform.isAndroid) {
    try {
      await InAppWebViewController.setWebContentsDebuggingEnabled(true);
    } catch (e, stack) {
      print("main: setWebContentsDebuggingEnabled error: $e\n$stack");
    }
  }
  try {
    tzData.initializeTimeZones();
  } catch (e, stack) {
    print("main: initializeTimeZones error: $e\n$stack");
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: BlocProvider(
        create: (_) => SplashBloc(TokenChannelService())..add(SplashStarted()),
        child: const SplashScreen(),
      ),
    );
  }
}

// ====================
// UI: SPLASH
// ====================
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<SplashBloc, SplashState>(
      listener: (context, state) {
        if (!state.isLoading && state.token != null) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => MainWebViewPage(pushToken: state.token!),
            ),
          );
        }
      },
      builder: (context, state) => Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: state.isLoading
              ? CircularPercentIndicator(
            radius: 60.0,
            lineWidth: 8.0,
            animation: true,
            percent: state.percent,
            center: const Text(
              "Loading...",
              style: TextStyle(
                  fontWeight: FontWeight.bold, color: Colors.white),
            ),
            progressColor: Colors.pink,
            backgroundColor: Colors.grey.shade800,
          )
              : const SizedBox.shrink(),
        ),
      ),
    );
  }
}

// ====================
// UI: MAIN WEBVIEW
// ====================
class MainWebViewPage extends StatelessWidget {
  final String pushToken;
  const MainWebViewPage({super.key, required this.pushToken});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => WebViewBloc(DeviceInfoService(), AppsFlyerService(), pushToken)..add(WebViewInit()),
      child: const MainWebViewScreen(),
    );
  }
}

class MainWebViewScreen extends StatefulWidget {
  const MainWebViewScreen({super.key});
  @override
  State<MainWebViewScreen> createState() => _MainWebViewScreenState();
}

class _MainWebViewScreenState extends State<MainWebViewScreen> {
  final String url = WEBVIEW_URL;
  bool hasTimeout = false;
  InAppWebViewController? _controller;

  void reloadWebView() {
    setState(() {
      hasTimeout = false;
    });
    _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<WebViewBloc, WebViewState>(
      builder: (context, state) {
        final webBloc = context.read<WebViewBloc>();
        return Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              if (!hasTimeout)
                SafeArea(
                  child: InAppWebView(
                    initialSettings: InAppWebViewSettings(
                      javaScriptEnabled: true,
                      disableDefaultErrorPage: true,
                      mediaPlaybackRequiresUserGesture: false,
                      allowsInlineMediaPlayback: true,
                      allowsPictureInPictureMediaPlayback: true,
                      useOnDownloadStart: true,
                      javaScriptCanOpenWindowsAutomatically: true,
                    ),
                    initialUrlRequest: URLRequest(url: WebUri(url)),
                    onWebViewCreated: (controller) {
                      _controller = controller;
                      webBloc.add(WebViewSetController(controller));
                      controller.addJavaScriptHandler(
                        handlerName: 'onServerResponse',
                        callback: (args) {
                          print("JS args: $args");
                          return args.reduce((curr, next) => curr + next);
                        },
                      );
                    },
                    onLoadStart: (controller, url) {
                      webBloc.add(WebViewSetController(controller));
                    },
                    onLoadStop: (controller, url) async {
                      try {
                        await webBloc.sendDeviceDataToWeb();
                        Future.delayed(const Duration(seconds: 6), () async {
                          await webBloc.sendRawDataToWeb();
                        });
                      } catch (e, stack) {
                        print("MainWebViewScreen.onLoadStop error: $e\n$stack");
                      }
                    },
                    shouldOverrideUrlLoading: (controller, navigationAction) async {
                      return NavigationActionPolicy.ALLOW;
                    },
                    onLoadError: (controller, url, code, message) {
                      print('MainWebViewScreen.onLoadError $code: $message');
                      if (code == -1001) {
                        setState(() {
                          hasTimeout = true;
                        });
                      }
                    },
                    onLoadHttpError: (controller, url, statusCode, description) {
                      print('MainWebViewScreen.onLoadHttpError $statusCode: $description');
                    },
                  ),
                ),
              if (hasTimeout)
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.cloud_off, color: Colors.white, size: 60),
                      const SizedBox(height: 16),
                      const Text(
                        "Время ожидания истекло",
                        style: TextStyle(color: Colors.white, fontSize: 18),
                      ),
                      const SizedBox(height: 8),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.deepPurple,
                        ),
                        onPressed: reloadWebView,
                        child: const Text("Повторить"),
                      ),
                    ],
                  ),
                ),
              if (state.isLoading)
                Center(
                  child: CircularPercentIndicator(
                    radius: 40.0,
                    lineWidth: 6.0,
                    animation: true,
                    percent: state.percent,
                    center: const Text(
                      "Loading...",
                      style: TextStyle(
                          fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    progressColor: Colors.deepPurple,
                    backgroundColor: Colors.grey.shade800,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ====================
// FCM BG Handler
// ====================
@pragma('vm:entry-point')
Future<void> _backgroundHandler(RemoteMessage msg) async {
  print("BG Message: ${msg.messageId}");
  print("BG Data: ${msg.data}");
}