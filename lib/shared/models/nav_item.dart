import 'package:flutter/material.dart';

class NavItem {
  const NavItem({
    required this.label,
    required this.icon,
    required this.location,
  });

  final String label;
  final IconData icon;
  final String location;
}
