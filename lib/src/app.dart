import 'package:flutter/material.dart';

import 'kiosk_screen.dart';
import 'services.dart';

class FichajeApp extends StatelessWidget {
  const FichajeApp({super.key, required this.services});
  final AppServices services;

  @override
  Widget build(BuildContext context) {
    const acidGreen = Color(0xffc6ff00);
    final scheme =
        ColorScheme.fromSeed(
          seedColor: acidGreen,
          brightness: Brightness.dark,
          surface: const Color(0xff111310),
        ).copyWith(
          primary: acidGreen,
          onPrimary: Colors.black,
          secondary: const Color(0xffaeb5aa),
          onSecondary: Colors.black,
          surfaceContainerLow: const Color(0xff171a16),
          surfaceContainer: const Color(0xff1d211b),
          surfaceContainerHigh: const Color(0xff272c24),
          outline: const Color(0xff596052),
          outlineVariant: const Color(0xff343a30),
        );
    return MaterialApp(
      title: 'MyUrbanScoot · Fichaje',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xff080a08),
        useMaterial3: true,
        textTheme: const TextTheme(
          displayLarge: TextStyle(
            fontSize: 76,
            fontWeight: FontWeight.w700,
            letterSpacing: -2,
          ),
          headlineLarge: TextStyle(fontSize: 38, fontWeight: FontWeight.w700),
          titleLarge: TextStyle(fontSize: 25, fontWeight: FontWeight.w600),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(180, 64),
            textStyle: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        cardTheme: const CardThemeData(
          color: Color(0xff171a16),
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
            side: BorderSide(color: Color(0xff343a30)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xff171a16),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: acidGreen, width: 2),
          ),
        ),
        navigationRailTheme: NavigationRailThemeData(
          backgroundColor: const Color(0xff0d0f0c),
          indicatorColor: acidGreen,
          selectedIconTheme: const IconThemeData(color: Colors.black),
          selectedLabelTextStyle: const TextStyle(
            color: acidGreen,
            fontWeight: FontWeight.w700,
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xff0d0f0c),
          foregroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
        ),
      ),
      home: KioskScreen(services: services),
    );
  }
}
