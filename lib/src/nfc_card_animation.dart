import 'dart:math' as math;

import 'package:flutter/material.dart';

enum NfcCardAnimationMode { scanning, recognized }

class AnimatedNfcCard extends StatefulWidget {
  const AnimatedNfcCard({super.key, required this.mode, required this.width});

  final NfcCardAnimationMode mode;
  final double width;

  @override
  State<AnimatedNfcCard> createState() => _AnimatedNfcCardState();
}

class _AnimatedNfcCardState extends State<AnimatedNfcCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(
        milliseconds: widget.mode == NfcCardAnimationMode.recognized
            ? 1050
            : 1500,
      ),
    );
    _start();
  }

  void _start() {
    if (widget.mode == NfcCardAnimationMode.recognized) {
      _controller.forward(from: 0);
    } else {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant AnimatedNfcCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode != widget.mode) {
      _controller.duration = Duration(
        milliseconds: widget.mode == NfcCardAnimationMode.recognized
            ? 1050
            : 1500,
      );
      _start();
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, child) {
      final value = Curves.easeInOutCubic.transform(_controller.value);
      final scanning = widget.mode == NfcCardAnimationMode.scanning;
      final recognized = widget.mode == NfcCardAnimationMode.recognized;
      final rotation = value * math.pi * 2;
      final scale = recognized
          ? 0.82 + (Curves.elasticOut.transform(value) * 0.18)
          : 0.96 + math.sin(value * math.pi * 2).abs() * 0.04;
      final glow = recognized
          ? (1 - (value - 0.72).abs()).clamp(0.25, 1.0)
          : 0.35 + math.sin(value * math.pi * 2).abs() * 0.45;

      return SizedBox(
        width: widget.width,
        height: widget.width * 0.68,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: widget.width * (0.72 + glow * 0.18),
              height: widget.width * (0.45 + glow * 0.12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.18 + glow * 0.34),
                    blurRadius: 42 + glow * 25,
                    spreadRadius: glow * 8,
                  ),
                ],
              ),
            ),
            Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.0018)
                ..rotateX(scanning ? math.sin(value * math.pi * 2) * 0.10 : 0)
                ..rotateY(rotation),
              child: Transform.scale(scale: scale, child: child),
            ),
            if (recognized)
              Opacity(
                opacity: Curves.easeIn.transform(value),
                child: Align(
                  alignment: const Alignment(0.82, -0.78),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Theme.of(context).colorScheme.primary,
                      boxShadow: const [
                        BoxShadow(color: Colors.black54, blurRadius: 14),
                      ],
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      color: Colors.black,
                      size: 30,
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
    child: Image.asset(
      'assets/branding/worker_nfc_card.png',
      width: widget.width,
      filterQuality: FilterQuality.high,
      fit: BoxFit.contain,
    ),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
