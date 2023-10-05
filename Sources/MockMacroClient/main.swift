let mock: NetworkingService = MockNetworkingService()

Task {
  try? await mock.fetchUsers()
}
