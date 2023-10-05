import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

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
public struct MockMacro {
  private enum Errors: Error, DiagnosticMessage {
    case onlyApplicableToProtocols
    case containsNonFunctions
    case containsOverloadedFunctions
    
    var message: String {
      switch self {
      case .onlyApplicableToProtocols:
        return "@Mock can only be applied to a protocol"
      case .containsNonFunctions:
        return "@Mock can only be used to mock functions in a protocol"
      case .containsOverloadedFunctions:
        return "@Mock cannot be used with protocols containing overloaded functions"
      }
    }
    
    var diagnosticID: SwiftDiagnostics.MessageID {
      switch self {
      case .onlyApplicableToProtocols:
        return .init(domain: "MockMacro", id: "onlyApplicableToProtocols")
      case .containsNonFunctions:
        return .init(domain: "MockMacro", id: "containsNonFunctions")
      case .containsOverloadedFunctions:
        return .init(domain: "MockMacro", id: "containsOverloadedFunctions")
      }
    }
    
    var severity: SwiftDiagnostics.DiagnosticSeverity {
      switch self {
      case .onlyApplicableToProtocols, .containsOverloadedFunctions:
        return .error
      case .containsNonFunctions:
        return .warning
      }
    }
    
    func diagnose(at node: some SyntaxProtocol) -> Diagnostic {
      Diagnostic(node: Syntax(node), message: self)
    }
  }
}

extension MockMacro: ExtensionMacro {
  public static func expansion(of node: AttributeSyntax, attachedTo declaration: some DeclGroupSyntax, providingExtensionsOf type: some TypeSyntaxProtocol, conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext) throws -> [ExtensionDeclSyntax] {
    guard let decl = declaration.as(ProtocolDeclSyntax.self) else {
      return []
    }

    let mockName = "Mock\(decl.name.text)"
    
    // Collect all the functions in the protocol
    let members = decl.memberBlock.members.compactMap { memberBlockItem in
      let item = memberBlockItem
        .as(MemberBlockItemSyntax.self)?
        .decl
        .as(FunctionDeclSyntax.self)
      if item == nil {
        context.diagnose(Errors.containsNonFunctions.diagnose(at: memberBlockItem))
      }
      return item
    }

    return [
      .init(
        extendedType: IdentifierTypeSyntax(name: decl.name),
        genericWhereClause: .init {
          .init(
            requirement: .sameTypeRequirement(
              .init(
                leftType: IdentifierTypeSyntax(name: .keyword(.Self)),
                equal: .binaryOperator("=="),
                rightType: IdentifierTypeSyntax(name: .identifier(mockName)))))
        }
      ) {
        .init(decl: FunctionDeclSyntax(
          modifiers: decl.modifiers + [.init(name: .keyword(.static))],
          name: .identifier("mock"),
          signature: .init(
            parameterClause: members.toFunctionParameterClause(for: mockName),
            returnClause: .init(type: IdentifierTypeSyntax(name: .keyword(.Self))))) {
          FunctionCallExprSyntax(
            calledExpression: DeclReferenceExprSyntax(baseName: .identifier(mockName)),
            leftParen: .leftParenToken(),
            arguments: .init {
              for member in members {
                .init(
                  label: member.name.text,
                  expression: DeclReferenceExprSyntax(baseName: member.name))
              }
            },
            rightParen: .rightParenToken()
          )
        })
      },
    ]
  }
}

extension MockMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext) throws -> [DeclSyntax]
  {
    // Check if the attached declaration is a protocol
    guard let decl = declaration.as(ProtocolDeclSyntax.self) else {
      if let decl = declaration.as(StructDeclSyntax.self) {
        throw DiagnosticsError(
          diagnostics: [
            Errors.onlyApplicableToProtocols.diagnose(at: decl.structKeyword)
          ])
      }
      throw DiagnosticsError(
        diagnostics: [
          Errors.onlyApplicableToProtocols.diagnose(at: declaration)
        ])
    }
    
    let mockName = "Mock\(decl.name.text)"

    // Collect all the functions in the protocol
    let members = decl.memberBlock.members.compactMap { memberBlockItem in
      let item = memberBlockItem
        .as(MemberBlockItemSyntax.self)?
        .decl
        .as(FunctionDeclSyntax.self)
      if item == nil {
        context.diagnose(Errors.containsNonFunctions.diagnose(at: memberBlockItem))
      }
      return item
    }

    // Check for overloaded functions
    var seenNames = Set<String>()
    for member in members {
      let name = member.name.text
      defer {
        seenNames.insert(name)
      }
      if seenNames.contains(name) {
        throw DiagnosticsError(
          diagnostics: [
            Errors.containsOverloadedFunctions.diagnose(at: member)
          ])
      }
    }

    // Create initializer
    let initDecl = InitializerDeclSyntax(
      modifiers: decl.modifiers,
      signature: .init(
        parameterClause: members.toFunctionParameterClause(for: mockName))) {
            for member in members {
              InfixOperatorExprSyntax(
                leftOperand: DeclReferenceExprSyntax(baseName: member.underscoredToken),
                operator: AssignmentExprSyntax(),
                rightOperand: DeclReferenceExprSyntax(baseName: member.name))
            }
          }

    // Create the mocked functions
    let functions = members.map { member in
      var function = member
      function.modifiers = decl.modifiers

      var functionCall: ExprSyntaxProtocol = FunctionCallExprSyntax(
        callee: DeclReferenceExprSyntax(
          baseName: member.underscoredToken),
        argumentList: {
          for parameter in member.signature.parameterClause.parameters {
            let paramName = parameter.secondName?.text ??  parameter.firstName.text
            LabeledExprSyntax(
             expression: DeclReferenceExprSyntax(baseName: .identifier(paramName)))
          }
        }
      )

      if member.signature.effectSpecifiers?.asyncSpecifier != nil {
        functionCall.leadingTrivia = .space
        functionCall = AwaitExprSyntax(
          expression: functionCall)
      }

      if member.signature.effectSpecifiers?.throwsSpecifier != nil {
        functionCall.leadingTrivia = .space
        functionCall = TryExprSyntax(
          expression: functionCall)
      }

      function.body = .init(statements: .init {
        functionCall
      })

      return function
    }

    // Create local storage for overrides
    let properties = members.map { member in
      VariableDeclSyntax(
        modifiers: [.init(name: .keyword(.private))],
        bindingSpecifier: .keyword(.let),
        bindings: [
          .init(
            pattern: IdentifierPatternSyntax(identifier: member.underscoredToken),
            typeAnnotation: .init(
              type: member.signature.toFunctionType())
          )
        ]
      )
    }

    // Create the mock
    let mockDecl = StructDeclSyntax(
      modifiers: decl.modifiers,
      name: .identifier(mockName),
      inheritanceClause: .init(inheritedTypes: [
        .init(type: IdentifierTypeSyntax(name: decl.name))
      ])
    ) {
        initDecl

        for function in functions {
          function
        }

        for property in properties {
          property
        }
    }
    
    // Extension

    return [
      .init(mockDecl),
    ]
  }
}

@main
struct MockMacroPlugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [
    MockMacro.self,
  ]
}

extension FunctionDeclSyntax {
  fileprivate var underscoredToken: TokenSyntax {
    .identifier("_\(name.text)")
  }
}

extension Array where Element == FunctionDeclSyntax {
  func toFunctionParameterClause(for typeName: String) -> FunctionParameterClauseSyntax {
    .init(
      parameters: .init {
        for element in self {
          FunctionParameterSyntax(
            leadingTrivia: .newline,
            firstName: element.name,
            type: AttributedTypeSyntax(
              attributes: [
                .attribute(.init(
                  attributeName: IdentifierTypeSyntax(name: .keyword(.escaping))))
              ],
              baseType: element.signature.toFunctionType()),
            defaultValue: .init(value: FunctionCallExprSyntax(
              calledExpression: DeclReferenceExprSyntax(baseName: .identifier("unimplemented")),
              leftParen: .leftParenToken(),
              arguments: .init {
                .init(expression: StringLiteralExprSyntax(content: "\(typeName).\(element.name.text)"))
              },
              rightParen: .rightParenToken()
            )))
        }
      })
  }
}

extension FunctionSignatureSyntax {
  func toFunctionType() -> FunctionTypeSyntax {
    FunctionTypeSyntax(
      parameters: parameterClause.parameters.toTupleTypeElementList(),
      effectSpecifiers: .init(
        asyncSpecifier: effectSpecifiers?.asyncSpecifier,
        throwsSpecifier: effectSpecifiers?.throwsSpecifier),
      returnClause: returnClause ?? .init(type: IdentifierTypeSyntax(name: .identifier("Void"))))
  }
}

extension FunctionParameterListSyntax {
  func toTupleTypeElementList() -> TupleTypeElementListSyntax {
    .init {
      for param in self {
        let paramName = param.secondName?.text ??  param.firstName.text
        TupleTypeElementSyntax(
          firstName: .wildcardToken(),
          secondName: .identifier(paramName),
          colon: .colonToken(),
          type: param.type)
      }
    }
  }
}
