//
//  File.swift
//  
//
//  Created by Matthew Cheok on 10/4/23.
//

import MockMacro

@Mock
public protocol NetworkingService {
  func fetchUsers() async throws -> [String]
  func notifications() async throws -> AsyncStream<[String]>
}

let test: NetworkingService = .mock()

