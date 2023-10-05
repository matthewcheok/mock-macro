import MacroTesting
import MockMacro
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

// Macro implementations build for the host, so the corresponding module is not available when cross-compiling. Cross-compiled tests may still make use of the macro itself in end-to-end tests.
#if canImport(MockMacroMacros)
import MockMacroMacros

@Mock
protocol NetworkingService {
  func fetchUsers() -> [String]
}

final class MockMacroTests: XCTestCase {
  override func invokeTest() {
    withMacroTesting(
//      isRecording: true,
      macros: [MockMacro.self]) {
      super.invokeTest()
    }
  }
  
  /// Test regular macro expansion
  func testMacroExpansion() throws {
    assertMacro {
      """
      @Mock
      protocol NetworkingService {
        func fetchUsers() async throws -> [String]
      }
      """
    } expansion: {
      """
      protocol NetworkingService {
        func fetchUsers() async throws -> [String]
      }

      struct MockNetworkingService: NetworkingService {
        init(\r
          fetchUsers: @escaping () async throws -> [String] = unimplemented("MockNetworkingService.fetchUsers")) {
          _fetchUsers = fetchUsers
        }
          func fetchUsers() async throws -> [String] {
          try await _fetchUsers()
        }
        private let _fetchUsers: () async throws -> [String]
      }
      """
    }
  }

  /// Test regular macro expansion with a public access control modifier
  func testMacroExpansionPublic() throws {
    assertMacro {
      """
      @Mock
      public protocol NetworkingService {
        func fetchUsers() async throws -> [String]
      }
      """
    } expansion: {
      """
      public protocol NetworkingService {
        func fetchUsers() async throws -> [String]
      }

      public struct MockNetworkingService: NetworkingService {
        public init(\r
          fetchUsers: @escaping () async throws -> [String] = unimplemented("MockNetworkingService.fetchUsers")) {
          _fetchUsers = fetchUsers
        }
        public
          func fetchUsers() async throws -> [String] {
          try await _fetchUsers()
        }
        private let _fetchUsers: () async throws -> [String]
      }
      """
    }
  }

  /// Test that calling functions with default values will cause test failures via `XCTestDynamicOverlay`
  func testDefaultValue() throws {
    let mock = MockNetworkingService()
    XCTExpectFailure("MockNetworkingService.fetchUsers is unimplemented")
    let _ = mock.fetchUsers()
  }

  /// Test that overloaded functions will cause the macro to fail to expand
  func testOverloadedFunctions() throws {
    assertMacro {
      """
      @Mock
      public protocol NetworkingService {
        func fetchUsers(_ userID: String) async throws -> [String]
        func fetchUsers(_ userNames: [String]) async throws -> [String]
      }
      """
    } diagnostics: {
      """
      @Mock
      public protocol NetworkingService {
        func fetchUsers(_ userID: String) async throws -> [String]
        func fetchUsers(_ userNames: [String]) async throws -> [String]
        ┬──────────────────────────────────────────────────────────────
        ╰─ 🛑 @Mock cannot be used with protocols containing overloaded functions
      }
      """
    }expansion: {
      """
      public protocol NetworkingService {
        func fetchUsers(_ userID: String) async throws -> [String]
        func fetchUsers(_ userNames: [String]) async throws -> [String]
      }
      """
    }
  }

  /// Test that expanding anything other than a protocol will cause the macro to fail to expand
  func testExpandStruct() throws {
    assertMacro {
      """
      @Mock
      struct Database {}
      """
    } diagnostics: {
      """
      @Mock
      struct Database {}
      ┬─────
      ╰─ 🛑 @Mock can only be applied to a protocol
      """
    }
  }

  /// Test that properties in the protocol result in warnings
  func testProtocolHasProperties() throws {
    assertMacro {
      """
      @Mock
      protocol DatabaseService {
        var userID: String { get }
      }
      """
    } diagnostics: {
      """
      @Mock
      protocol DatabaseService {
        var userID: String { get }
        ┬─────────────────────────
        ╰─ ⚠️ @Mock can only be used to mock functions in a protocol
      }
      """
    } expansion: {
      """
      protocol DatabaseService {
        var userID: String { get }
      }

      struct MockDatabaseService: DatabaseService {
        init() {
        }
      }
      """
    }
  }
}
#endif
