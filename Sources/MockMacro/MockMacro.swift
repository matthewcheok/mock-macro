@_exported import XCTestDynamicOverlay

/// A macro that produces a mock value for a protocol, allowing its functions to be overridden in the initializer. For example,
///
/// ```swift
/// @Mock
/// protocol NetworkingService {
///   func fetchUsers() async throws -> [String]
/// }
/// ```
///
/// produces the following mock:
/// ```swift
/// struct MockNetworkingService {
///   init(
///     fetchUsers: @escaping () async throws -> [String] = unimplemented("MockNetworkingService.fetchUsers")) {
///     _fetchUsers = fetchUsers
///   }
///
///   func fetchUsers() async throws -> [String] {
///     try await _fetchUsers()
///   }
///
///   private let _fetchUsers: () async throws -> [String]
/// }
/// ```
///
/// The default value uses `XCTestDynamicOverlay` in order to fatal error at runtime
/// but provide a test failure at test time.
/// The mock has the same access control as the attached protocol.
@attached(peer, names: prefixed(Mock))
@attached(extension, names: arbitrary)
public macro Mock() = #externalMacro(module: "MockMacroMacros", type: "MockMacro")
