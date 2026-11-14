import Foundation
import GameController

// 0.41: game controllers as triggers, like BetterTouchTool's: a button on an Xbox, PlayStation, Switch or
// other Bluetooth or USB controller starts a macro (for example the shoulder buttons for the next and
// previous slide, or a button to mute a call). Uses Apple's GameController framework; Toolbelt only
// listens while a macro uses this, and keeps listening while it's in the background.

/// The buttons offered, by the names Apple's framework uses for the standard layout.
enum GamepadButton: String, CaseIterable, Identifiable {
    case a = "A", b = "B", x = "X", y = "Y"
    case leftShoulder = "L1", rightShoulder = "R1", leftTrigger = "L2", rightTrigger = "R2"
    case up = "Up", down = "Down", left = "Left", right = "Right"
    case menu = "Menu", options = "Options", home = "Home"
    case leftStick = "L3", rightStick = "R3"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .a: return "A (Xbox) / ✕ (PlayStation) / B (Switch)"
        case .b: return "B (Xbox) / ◯ (PlayStation) / A (Switch)"
        case .x: return "X (Xbox) / ◻ (PlayStation) / Y (Switch)"
        case .y: return "Y (Xbox) / △ (PlayStation) / X (Switch)"
        case .leftShoulder: return "Left shoulder (LB / L1 / L)"
        case .rightShoulder: return "Right shoulder (RB / R1 / R)"
        case .leftTrigger: return "Left trigger (LT / L2 / ZL)"
        case .rightTrigger: return "Right trigger (RT / R2 / ZR)"
        case .up: return "D-pad up"
        case .down: return "D-pad down"
        case .left: return "D-pad left"
        case .right: return "D-pad right"
        case .menu: return "Menu / Options / +"
        case .options: return "View / Share / −"
        case .home: return "Home (Xbox / PS / Home button)"
        case .leftStick: return "Left stick pressed in (L3)"
        case .rightStick: return "Right stick pressed in (R3)"
        }
    }
}

/// Turns "pressed / not pressed" readings into presses: a button counts once when it goes down. Pure.
struct ButtonEdges {
    private var down: Set<String> = []

    /// True when this reading is a new press.
    mutating func update(_ button: String, pressed: Bool) -> Bool {
        if pressed { return down.insert(button).inserted }
        down.remove(button)
        return false
    }
}

@MainActor
final class GameControllerWatcher {
    /// Called with the button's name and the controller's name.
    var onPress: ((GamepadButton, String) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var edges = ButtonEdges()
    private(set) var isWatching = false

    var connectedNames: [String] { GCController.controllers().map { $0.vendorName ?? "Controller" } }

    func start() {
        guard !isWatching else { return }
        isWatching = true
        GCController.shouldMonitorBackgroundEvents = true
        observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            MainActor.assumeIsolated { self?.attach(controller) }
        })
        GCController.controllers().forEach(attach)
        GCController.startWirelessControllerDiscovery {}
    }

    func stop() {
        guard isWatching else { return }
        isWatching = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        for controller in GCController.controllers() { controller.extendedGamepad?.valueChangedHandler = nil }
        GCController.stopWirelessControllerDiscovery()
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        let name = controller.vendorName ?? "Controller"
        pad.valueChangedHandler = { [weak self] gamepad, _ in
            let readings = Self.readings(gamepad)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for (button, pressed) in readings where self.edges.update(button.rawValue, pressed: pressed) {
                        self.onPress?(button, name)
                    }
                }
            }
        }
    }

    private nonisolated static func readings(_ pad: GCExtendedGamepad) -> [(GamepadButton, Bool)] {
        var list: [(GamepadButton, Bool)] = [
            (.a, pad.buttonA.isPressed), (.b, pad.buttonB.isPressed), (.x, pad.buttonX.isPressed), (.y, pad.buttonY.isPressed),
            (.leftShoulder, pad.leftShoulder.isPressed), (.rightShoulder, pad.rightShoulder.isPressed),
            (.leftTrigger, pad.leftTrigger.isPressed), (.rightTrigger, pad.rightTrigger.isPressed),
            (.up, pad.dpad.up.isPressed), (.down, pad.dpad.down.isPressed), (.left, pad.dpad.left.isPressed), (.right, pad.dpad.right.isPressed),
            (.menu, pad.buttonMenu.isPressed),
        ]
        if let options = pad.buttonOptions { list.append((.options, options.isPressed)) }
        if let home = pad.buttonHome { list.append((.home, home.isPressed)) }
        if let stick = pad.leftThumbstickButton { list.append((.leftStick, stick.isPressed)) }
        if let stick = pad.rightThumbstickButton { list.append((.rightStick, stick.isPressed)) }
        return list
    }
}
