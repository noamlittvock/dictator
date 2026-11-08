import XCTest
@testable import Dictator

/// Synthetic worker-produced inputs. Expected outcomes were checked by the
/// parent independently; two Qwen coordinates were corrected before inclusion.
final class WorkspaceLaunchWorkerFixtureTests: XCTestCase {
    private struct CenterCase: Decodable { var name: String; var display: WorkspaceRect; var window: WorkspaceRect; var expected: WorkspaceRect }
    private struct IdleCase: Decodable {
        struct App: Decodable { var bundleID: String; var lastActivatedAt: Double?; var isHidden: Bool }
        var name: String; var apps: [App]; var expectedHidden: [String]
    }
    func testSyntheticMultiDisplayCenteringCases() throws {
        let cases = try JSONDecoder().decode([CenterCase].self, from: Data(Self.centerJSON.utf8))
        XCTAssertEqual(cases.count, 5)
        for fixture in cases {
            let snapshot = WorkspaceSnapshot(displays: [WorkspaceDisplay(id: "main", visibleFrame: fixture.display, isMain: true)],
                windows: [WorkspaceWindow(id: "w", bundleID: "app", frame: fixture.window)], frontmostWindowID: "w")
            let routine = WorkspaceRoutine(name: "Center", actions: [WorkspaceAction(kind: .centerLastWindow)])
            let plan = WorkspacePlanner.plan(routine: routine, snapshot: snapshot, protectedBundleIDs: [])
            XCTAssertEqual(plan.operations, [.moveWindow(id: "w", frame: fixture.expected)], fixture.name)
        }
    }
    func testSyntheticIdleProtectionCases() throws {
        let cases = try JSONDecoder().decode([IdleCase].self, from: Data(Self.idleJSON.utf8))
        XCTAssertEqual(cases.count, 6)
        for fixture in cases {
            let applications = fixture.apps.map { app in
                WorkspaceApplication(bundleID: app.bundleID, isHidden: app.isHidden,
                    lastActivatedAt: app.lastActivatedAt.map { Date(timeIntervalSince1970: $0) })
            }
            let snapshot = WorkspaceSnapshot(capturedAt: Date(timeIntervalSince1970: 10000),
                windows: [WorkspaceWindow(id: "front", bundleID: "app.editor")], applications: applications, frontmostWindowID: "front")
            let routine = WorkspaceRoutine(name: "Hide", actions: [WorkspaceAction(kind: .hideIdleApps, bundleIDs: applications.map(\.bundleID), idleMinutes: 60)])
            let plan = WorkspacePlanner.plan(routine: routine, snapshot: snapshot, protectedBundleIDs: ["app.dictator"])
            XCTAssertEqual(plan.operations, fixture.expectedHidden.sorted().map { .hideApp(bundleID: $0) }, fixture.name)
        }
    }
    private static let centerJSON = #"""
[
  {
    "name": "Negative-X Screen",
    "display": {
      "x": -800,
      "y": 0,
      "width": 1600,
      "height": 1024
    },
    "window": {
      "x": 0,
      "y": 0,
      "width": 500,
      "height": 300
    },
    "expected": {
      "x": -250.0,
      "y": 362.0,
      "width": 500,
      "height": 300
    }
  },
  {
    "name": "Negative-Y Screen",
    "display": {
      "x": 0,
      "y": -600,
      "width": 1920,
      "height": 1200
    },
    "window": {
      "x": 0,
      "y": 0,
      "width": 700,
      "height": 400
    },
    "expected": {
      "x": 610.0,
      "y": -200.0,
      "width": 700,
      "height": 400
    }
  },
  {
    "name": "Too-Large Window",
    "display": {
      "x": 0,
      "y": 0,
      "width": 1366,
      "height": 768
    },
    "window": {
      "x": 0,
      "y": 0,
      "width": 2000,
      "height": 1500
    },
    "expected": {
      "x": 0,
      "y": 0,
      "width": 1366,
      "height": 768
    }
  },
  {
    "name": "Ordinary 1440x900 Screen",
    "display": {
      "x": 0,
      "y": 0,
      "width": 1440,
      "height": 900
    },
    "window": {
      "x": 0,
      "y": 0,
      "width": 800,
      "height": 600
    },
    "expected": {
      "x": 320,
      "y": 150,
      "width": 800,
      "height": 600
    }
  },
  {
    "name": "Narrow Window",
    "display": {
      "x": 0,
      "y": 0,
      "width": 1280,
      "height": 800
    },
    "window": {
      "x": 0,
      "y": 0,
      "width": 100,
      "height": 50
    },
    "expected": {
      "x": 590,
      "y": 375,
      "width": 100,
      "height": 50
    }
  }
]
"""#
    private static let idleJSON = #"""
[
  {
    "name": "old_app_hidden",
    "apps": [
      {
        "bundleID": "com.old",
        "lastActivatedAt": 1000,
        "isHidden": false
      },
      {
        "bundleID": "com.recent2",
        "lastActivatedAt": 8000,
        "isHidden": false
      }
    ],
    "expectedHidden": [
      "com.old"
    ]
  },
  {
    "name": "recent_app_hidden",
    "apps": [
      {
        "bundleID": "com.recent",
        "lastActivatedAt": 6399,
        "isHidden": false
      }
    ],
    "expectedHidden": [
      "com.recent"
    ]
  },
  {
    "name": "unknown_not_hidden",
    "apps": [
      {
        "bundleID": "com.unknown",
        "lastActivatedAt": null,
        "isHidden": false
      }
    ],
    "expectedHidden": []
  },
  {
    "name": "frontmost_not_hidden",
    "apps": [
      {
        "bundleID": "app.editor",
        "lastActivatedAt": 5000,
        "isHidden": false
      },
      {
        "bundleID": "com.side",
        "lastActivatedAt": 3000,
        "isHidden": false
      }
    ],
    "expectedHidden": [
      "com.side"
    ]
  },
  {
    "name": "protected_not_hidden",
    "apps": [
      {
        "bundleID": "app.dictator",
        "lastActivatedAt": 2000,
        "isHidden": false
      },
      {
        "bundleID": "com.side2",
        "lastActivatedAt": 4000,
        "isHidden": false
      }
    ],
    "expectedHidden": [
      "com.side2"
    ]
  },
  {
    "name": "already_hidden_excluded",
    "apps": [
      {
        "bundleID": "com.alreadyhidden",
        "lastActivatedAt": 1000,
        "isHidden": true
      },
      {
        "bundleID": "com.new",
        "lastActivatedAt": 3000,
        "isHidden": false
      }
    ],
    "expectedHidden": [
      "com.new"
    ]
  }
]
"""#
}
