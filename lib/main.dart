import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:http/http.dart' as http;
import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:simple_frame_app/tx/text_sprite_block.dart';

void main() => runApp(const MainApp());

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => MainAppState();
}

/// SimpleFrameAppState mixin helps to manage the lifecycle of the Frame connection outside of this file
class MainAppState extends State<MainApp> with SimpleFrameAppState {
  late stt.SpeechToText _speechToText;
  bool _isAvailable = false;
  bool _isListening = false;
  String _translatedText = "";
  static const _textStyle = TextStyle(fontSize: 30);
  String _selectedInputLanguage = 'de';
  String _selectedTargetLanguage = 'ja';

  final List<String> _languages = ['ja', 'en', 'de', 'it', 'fr', 'es', 'ar', 'zh', 'el', 'ko', 'tr', 'auto'];
  final ScrollController _scrollController = ScrollController();
  final ScrollController _logScrollController = ScrollController(); // Controller for log auto-scrolling

  // Für die Anzeige der gerenderten Bilder in der App
  final List<Image> _images = [];

  // Für das Speichern von Log-Nachrichten
  final List<String> _logMessages = [];

  MainAppState() {
    Logger.root.level = Level.FINE;
    Logger.root.onRecord.listen((record) {
      String logMessage = '${record.level.name}: [${record.loggerName}] ${record.time}: ${record.message}';
      debugPrint(logMessage);
      _addLogMessage(logMessage);
    });
  }

  // Methode zum Hinzufügen von Log-Nachrichten in die Liste
  void _addLogMessage(String message) {
    setState(() {
      _logMessages.add(message);
    });
    _scrollToBottom();
  }

  // Methode zum automatischen Scrollen ans Ende der Logs
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.animateTo(
          _logScrollController.position.maxScrollExtent,
          duration: Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _speechToText = stt.SpeechToText();
    currentState = ApplicationState.initializing;
    _initSpeechRecognition();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  bool shouldRestartListening = true; // Flag, um das automatische Neustarten zu steuern

  void _initSpeechRecognition() async {
    _isAvailable = await _speechToText.initialize(
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          _isListening = false;
          setState(() {});

          // Restart listening as quickly as possible after stopping
          if (shouldRestartListening) {
            Future.delayed(Duration(milliseconds: 200), () {
              if (!_isListening && shouldRestartListening) {
                _log.info('Restarting speech recognition for continuous translation.');
                _restartListening();
              }
            });
          }
        }
      },
      onError: (error) {
        _log.severe('Speech Recognition Error: $error');
        // Restart listening immediately after an error
        if (shouldRestartListening) {
          Future.delayed(Duration(milliseconds: 200), () {
            _restartListening();
          });
        }
      },
    );
    currentState = ApplicationState.disconnected;
    if (mounted) setState(() {});
  }

  void _restartListening() {
    if (!_isListening && _isAvailable && shouldRestartListening) {
      _startListening();
    }
  }

  void _startListening() async {
    if (_isAvailable && !_isListening) {
      _translatedText = '';
      setState(() {});

      try {
        await _speechToText.listen(
          onResult: (result) {
            if (result.finalResult) {
              _log.info('Finales Ergebnis erreicht: ${result.recognizedWords}');
              _translateAndSendTextToFrame(result.recognizedWords);
            } else {
              _log.info('Partielles Ergebnis: ${result.recognizedWords}');
            }
          },
          localeId: _selectedInputLanguage,
          listenFor: Duration(minutes: 5),  // Längeres Timeout für kontinuierliches Zuhören
          pauseFor: Duration(seconds: 20),  // Längere Pausen erlauben
          partialResults: true,             // Zwischenresultate aktivieren
        );
        _isListening = true;
        setState(() {});
      } catch (e) {
        _log.severe('Error starting speech recognition: $e');
      }
    }
  }

  void _stopListening() async {
    if (_isListening) {
      shouldRestartListening = false; // Automatisches Neustarten deaktivieren

      await Future.delayed(Duration(milliseconds: 50));

      await _speechToText.stop();
      _isListening = false;
      setState(() {});
    }
  }

  void _manualStartListening() {
    shouldRestartListening = true; // Automatisches Neustarten aktivieren
    _startListening();
  }

  @override
  Future<void> run() async {
    _log.info('Starting run()');
    currentState = ApplicationState.running;
    if (mounted) setState(() {});
    shouldRestartListening = true;
    _startListening();
  }

  @override
  Future<void> cancel() async {
    _stopListening();
    currentState = ApplicationState.ready;
    if (mounted) setState(() {});
  }

  bool _isSending = false;

  void _translateAndSendTextToFrame(String text) async {
    if (text.isNotEmpty && !_isSending) {
      _isSending = true;
      try {
        await Future.delayed(Duration(milliseconds: 500));

        String translatedText = await translateText(
            text, _selectedInputLanguage, _selectedTargetLanguage);

        _log.info('Übersetzung erfolgreich: $translatedText');

        if (translatedText.isEmpty) {
          _log.severe('Die Übersetzung ist leer.');
          _isSending = false;
          return;
        }

        _log.info('Sende den übersetzten Text an das Frame-Display.');

        await _sendTextToFrame(translatedText);

        setState(() {
          _translatedText = translatedText;
        });
      } catch (e) {
        _log.severe('Fehler beim Senden des übersetzten Textes an das Frame: $e');
      } finally {
        _isSending = false;
      }
    }
  }

  Future<void> _sendTextToFrame(String text) async {
    if (text.isNotEmpty) {
      try {
        var tsb = TxTextSpriteBlock(
          msgCode: 0x20,
          width: 640,
          fontSize: 40,
          displayRows: 4,
          fontFamily: null,
          text: text,
        );

        await tsb.rasterize();
        _log.info('TxTextSpriteBlock vorbereitet.');

        final pngBytes = await tsb.toPngBytes();
        _log.info('TxTextSpriteBlock PNG Bytes length: ${pngBytes.length} bytes');

        await frame!.sendMessage(tsb);
        _log.info('TxTextSpriteBlock gesendet');

        for (var line in tsb.lines) {
          await frame!.sendMessage(line);
          _log.info('TextSpriteLine gesendet: Zeile');
          await Future.delayed(Duration(milliseconds: 20));
        }

        currentState = ApplicationState.ready;
        if (mounted) setState(() {});
      } catch (e) {
        _log.severe('Fehler beim Senden des Textes an das Frame: $e');
      }
    }
  }

  Future<String> translateText(
      String text, String sourceLang, String targetLang) async {
    try {
      var url = Uri.parse('LINK.TO.LIBRETRANSLATE/translate');
      var response = await http.post(url,
          headers: {
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'q': text,
            'source': sourceLang,
            'target': targetLang,
            'format': 'text',
            'api_key': 'LIBRETRANSLATE-API-KEY',
            
          }));

      if (response.statusCode == 200) {
        var data = jsonDecode(utf8.decode(response.bodyBytes));
        _log.info('Translation successful: ${data['translatedText']}');
        return data['translatedText'];
      } else {
        _log.severe('Failed to translate text: ${response.body}');
        return text;
      }
    } catch (e) {
      _log.severe('Error translating text: $e');
      return text;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Frame Sprite Translator',
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
            title: const Text('Frame Speech-to-Text'),
            actions: [getBatteryWidget()]),
        body: SingleChildScrollView(
          controller: _scrollController,
          child: Center(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ..._images,
                  const SizedBox(height: 20),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(_translatedText, style: _textStyle),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: () async {
                      await _sendTextToFrame('Hello, friend!\nمرحبا يا صديق\nこんにちは、友人！\n朋友你好！\nПривет, друг!\nשלום, חבר\n안녕, 친구!');
                    },
                    child: const Text('Send Test'),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      DropdownButton<String>(
                        value: _selectedInputLanguage,
                        items: _languages
                            .map((lang) => DropdownMenuItem<String>(
                                  value: lang,
                                  child: Text(lang.toUpperCase()),
                                ))
                            .toList(),
                        onChanged: (value) {
                          setState(() {
                            _selectedInputLanguage = value!;
                          });
                        },
                        hint: const Text("Input Language"),
                      ),
                      DropdownButton<String>(
                        value: _selectedTargetLanguage,
                        items: _languages
                            .map((lang) => DropdownMenuItem<String>(
                                  value: lang,
                                  child: Text(lang.toUpperCase()),
                                ))
                            .toList(),
                        onChanged: (value) {
                          setState(() {
                            _selectedTargetLanguage = value!;
                          });
                        },
                        hint: const Text("Target Language"),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // Log Anzeige
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Logs:', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  ),
                  Container(
                    height: 200,  // Höhe der Logs
                    child: ListView.builder(
                      controller: _logScrollController, // Auto-scroll controller
                      itemCount: _logMessages.length,
                      itemBuilder: (context, index) {
                        return Text(
                          _logMessages[index],
                          style: TextStyle(fontSize: 12, color: Colors.white),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        floatingActionButton: getFloatingActionButtonWidget(
          const Icon(Icons.mic),
          const Icon(Icons.mic_off),
        ),
        persistentFooterButtons: getFooterButtonsWidget(),
      ),
    );
  }
}
