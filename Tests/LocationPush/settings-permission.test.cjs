const assert = require('node:assert/strict');
const test = require('node:test');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');

const source = readFileSync(resolve(__dirname, '../../ParentalControl/Views/SettingsView.swift'), 'utf8');

test('location settings card requires child parent mode and missing Always permission', () => {
  assert.match(source, /if appState\.deviceRole == \.child,\s*appState\.isParentModeActive,\s*appState\.childLocationAuthorizationStatus != \.authorizedAlways\s*\{\s*locationPermissionSection/);
});

test('permission refresh belongs to Settings, even when the card is hidden', () => {
  const container = source.split('private var premiumSection')[0];
  assert.match(container, /\.onAppear \{ refreshLocationPermissionStatus\(\) \}/);
  assert.match(container, /\.onChange\(of: scenePhase\) \{ _, phase in\s*if phase == \.active \{ refreshLocationPermissionStatus\(\) \}/);
  assert.match(container, /private func refreshLocationPermissionStatus\(\) \{\s*guard appState\.deviceRole == \.child else \{ return \}\s*appState\.refreshChildLocationAuthorizationStatus\(\)\s*\}/);
});
