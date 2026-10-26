#pragma once

class Agent;
class Engine;
class Instance;
class QQmlApplicationEngine;
class Theme;

// What the window needs, set up the same way for the app and for the
// offscreen harness that checks and photographs it.
namespace App {

// Once per process, before the QML engine: the Material style and the
// Omarchy font.
void prepare();

// The objects QML reaches by name, and the window. instance may be null
// (the harness runs without one). False when Main.qml didn't load.
bool load(QQmlApplicationEngine &qml, Theme &theme, Engine &engine, Agent &agent, Instance *instance);

} // namespace App
