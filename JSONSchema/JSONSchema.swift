//
//  JSONSchema.swift
//  JSONSchema
//
//  Created by Kyle Fuller on 07/03/2015.
//  Copyright (c) 2015 Cocode. All rights reserved.
//

import Foundation

public enum Type: Swift.String {
  case Object = "object"
  case Array = "array"
  case String = "string"
  case Integer = "integer"
  case Number = "number"
  case Boolean = "boolean"
  case Null = "null"
}

public struct Schema {
  public let title:String?
  public let description:String?

  public let type:[Type]?

  let schema:[String:AnyObject]

  public init(_ schema:[String:AnyObject]) {
    title = schema["title"] as? String
    description = schema["description"] as? String

    if let type = schema["type"] as? String {
      if let type = Type(rawValue: type) {
        self.type = [type]
      }
    } else if let types = schema["type"] as? [String] {
      type = map(filter(map(types) { Type(rawValue: $0) }) { $0 != nil }) { $0! }
    }

    self.schema = schema
  }

  public func validate(data:AnyObject) -> ValidationResult {
    return JSONSchema.validate(data, [:])
  }
}


/// Returns a set of validators for a schema and document
func validators(schema:[String:AnyObject]) -> [Validator] {
  var validators = [Validator]()

  if let type: AnyObject = schema["type"] {
    validators.append(validateType(type))
  }

  if let allOf = schema["allOf"] as? [[String:AnyObject]] {
    validators += reduce(map(allOf, JSONSchema.validators), [], +)
  }

  if let anyOfSchemas = schema["anyOf"] as? [[String:AnyObject]] {
    let anyOfValidators = map(map(anyOfSchemas, JSONSchema.validators), allOf) as [Validator]
    validators.append(anyOf(anyOfValidators))
  }

  if let oneOfSchemas = schema["oneOf"] as? [[String:AnyObject]] {
    let oneOfValidators = map(map(oneOfSchemas, JSONSchema.validators), allOf) as [Validator]
    validators.append(oneOf(oneOfValidators))
  }

  if let notSchema = schema["not"] as? [String:AnyObject] {
    let notValidator = allOf(JSONSchema.validators(notSchema))
    validators.append(not(notValidator))
  }

  if let enumValues = schema["enum"] as? [AnyObject] {
    validators.append(validateEnum(enumValues))
  }

  // String

  if let maxLength = schema["maxLength"] as? Int {
    validators.append(validateLength(<=, maxLength, "Length of string is larger than max length \(maxLength)"))
  }

  if let minLength = schema["minLength"] as? Int {
    validators.append(validateLength(>=, minLength, "Length of string is smaller than minimum length \(minLength)"))
  }

  if let pattern = schema["pattern"] as? String {
    validators.append(validatePattern(pattern))
  }

  // Numerical

  if let multipleOf = schema["multipleOf"] as? Double {
    validators.append(validateMultipleOf(multipleOf))
  }

  if let minimum = schema["minimum"] as? Double {
    validators.append(validateNumericLength(minimum, >=, >, schema["exclusiveMinimum"] as? Bool, "Value is lower than minimum value of \(minimum)"))
  }

  if let maximum = schema["maximum"] as? Double {
    validators.append(validateNumericLength(maximum, <=, <, schema["exclusiveMaximum"] as? Bool, "Value exceeds maximum value of \(maximum)"))
  }

  // Array

  if let minItems = schema["minItems"] as? Int {
    validators.append(validateArrayLength(minItems, >=, "Length of array is smaller than the minimum \(minItems)"))
  }

  if let maxItems = schema["maxItems"] as? Int {
    validators.append(validateArrayLength(maxItems, <=, "Length of array is greater than maximum \(maxItems)"))
  }

  if let uniqueItems = schema["uniqueItems"] as? Bool {
    if uniqueItems {
      validators.append(validateUniqueItems)
    }
  }

  if let items = schema["items"] as? [String:AnyObject] {
    let itemsValidators = allOf(JSONSchema.validators(items))

    func validateItems(document:AnyObject) -> ValidationResult {
      if let document = document as? [AnyObject] {
        return flatten(map(document, itemsValidators))
      }

      return .Valid
    }

    validators.append(validateItems)
  } else if let items = schema["items"] as? [[String:AnyObject]] {
    func createAdditionalItemsValidator(additionalItems:AnyObject?) -> Validator {
      if let additionalItems = additionalItems as? [String:AnyObject] {
        return allOf(JSONSchema.validators(additionalItems))
      }

      let additionalItems = additionalItems as? Bool ?? true
      if additionalItems {
        return validValidation
      }

      return invalidValidation("Additional results are not permitted in this array.")
    }

    let additionalItemsValidator = createAdditionalItemsValidator(schema["additionalItems"])
    let itemValidators = map(items, JSONSchema.validators)

    func validateItems(value:AnyObject) -> ValidationResult {
      if let value = value as? [AnyObject] {
        var results = [ValidationResult]()

        for (index, element) in enumerate(value) {
          if index >= itemValidators.count {
            results.append(additionalItemsValidator(element))
          } else {
            let validators = allOf(itemValidators[index])
            results.append(validators(value:element))
          }
        }

        return flatten(results)
      }

      return .Valid
    }

    validators.append(validateItems)
  }

  if let maxProperties = schema["maxProperties"] as? Int {
    validators.append(validatePropertiesLength(maxProperties, >=, "Amount of properties is greater than maximum permitted"))
  }

  if let minProperties = schema["minProperties"] as? Int {
    validators.append(validatePropertiesLength(minProperties, <=, "Amount of properties is less than the required amount"))
  }

  if let required = schema["required"] as? [String] {
    validators.append(validateRequired(required))
  }

  if (schema["properties"] != nil) || (schema["patternProperties"] != nil) || (schema["additionalProperties"] != nil) {
    func createAdditionalPropertiesValidator(additionalProperties:AnyObject?) -> Validator {
      if let additionalProperties = additionalProperties as? [String:AnyObject] {
        return allOf(JSONSchema.validators(additionalProperties))
      }

      let additionalProperties = additionalProperties as? Bool ?? true
      if additionalProperties {
        return validValidation
      }

      return invalidValidation("Additional properties are not permitted in this object.")
    }

    func createPropertiesValidators(properties:[String:[String:AnyObject]]?) -> [String:Validator]? {
      if let properties = properties {
        return Dictionary(map(properties.keys) {
          key in (key, allOf(JSONSchema.validators(properties[key]!)))
        })
      }

      return nil
    }

    let additionalPropertyValidator = createAdditionalPropertiesValidator(schema["additionalProperties"])
    let properties = createPropertiesValidators(schema["properties"] as? [String:[String:AnyObject]])
    let patternProperties = createPropertiesValidators(schema["patternProperties"] as? [String:[String:AnyObject]])
    validators.append(validateProperties(properties, patternProperties, additionalPropertyValidator))
  }

  func validateDependency(key:String, validator:Validator)(value:AnyObject) -> ValidationResult {
    if let value = value as? [String:AnyObject] {
      if (value[key] != nil) {
        return validator(value)
      }
    }

    return .Valid
  }

  func validateDependencies(key:String, dependencies:[String])(value:AnyObject) -> ValidationResult {
    if let value = value as? [String:AnyObject] {
      if (value[key] != nil) {
        return flatten(map(dependencies) { dependency in
          if value[dependency] == nil {
            return .Invalid(["'\(key)' is missing it's dependency of '\(dependency)'"])
          }
          return .Valid
        })
      }
    }

    return .Valid
  }

  if let dependencies = schema["dependencies"] as? [String:AnyObject] {
    for (key, dependencies) in dependencies {
      if let dependencies = dependencies as? [String: AnyObject] {
        let schema = allOf(JSONSchema.validators(dependencies))
        validators.append(validateDependency(key, schema))
      } else if let dependencies = dependencies as? [String] {
        validators.append(validateDependencies(key, dependencies))
      }
    }
  }

  return validators
}

public func validate(value:AnyObject, schema:[String:AnyObject]) -> ValidationResult {
  let validator = allOf(validators(schema))
  let result = validator(value: value)
  return result
}

/// Extension for dictionary providing initialization from array of elements
extension Dictionary {
  init(_ pairs: [Element]) {
    self.init()

    for (key, value) in pairs {
      self[key] = value
    }
  }
}
