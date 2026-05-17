import Foundation

final class SourceKitObfuscator: ObfuscatorProtocol {
    let sourceKit: SourceKit
    let logger: LoggerProtocol
    let dataStore: SourceKitObfuscatorDataStore
    let ignorePublic: Bool
    let namesToIgnore: Set<String>
    weak var delegate: ObfuscatorDelegate?

    init(sourceKit: SourceKit, logger: LoggerProtocol, dataStore: SourceKitObfuscatorDataStore, namesToIgnore: Set<String>, ignorePublic: Bool) {
        self.sourceKit = sourceKit
        self.logger = logger
        self.dataStore = dataStore
        self.ignorePublic = ignorePublic
        self.namesToIgnore = namesToIgnore
    }

    var requests: sourcekitd_requests! {
        sourceKit.requests
    }

    var keys: sourcekitd_keys! {
        sourceKit.keys
    }
}

// MARK: Indexing

extension SourceKitObfuscator {
    func registerModuleForObfuscation(_ module: Module) throws {
        let compilerArguments = SKRequestArray(sourcekitd: sourceKit)
        module.compilerArguments.forEach(compilerArguments.append(_:))
        try module.sourceFiles.sorted { $0.path < $1.path }.forEach { file in
            logger.log("--- Indexing: \(file.name)")
            let req = SKRequestDictionary(sourcekitd: sourceKit)
            req[keys.request] = requests.indexsource
            req[keys.sourcefile] = file.path
            req[keys.compilerargs] = compilerArguments
            let response = try sourceKit.sendSync(req)
            logger.log("--- Preprocessing indexing result of: \(file.name)")
            response.recurseEntities { [unowned self] dict in
                self.preprocess(declarationEntity: dict, ofFile: file, fromModule: module)
            }
            dataStore.moduleForFile[file.path] = module
////BASE:
//            logger.log("--- Preprocessing indexing result of: \(file.name)")
//            response.recurseEntities { [unowned self] dict in
//                self.preprocess(declarationEntity: dict, ofFile: file, fromModule: module)
//            }
////AGGRESSIVE:
//            var visited1 = Set<String>()
//            response.recurseEntities(visited: &visited1) { [unowned self] dict in
//                self.preprocess(declarationEntity: dict, ofFile: file, fromModule: module)
//            }

            logger.log("--- Processing indexing result of: \(file.name)")
            try response.recurseEntities { [unowned self] dict in
                if self.ignorePublic, dict.isPublic { return }
                try self.process(declarationEntity: dict, ofFile: file, fromModule: module)
            }
//// BASE:
//            logger.log("--- Processing indexing result of: \(file.name)")
//            try response.recurseEntities { [unowned self] dict in
//                if self.ignorePublic, dict.isPublic {
//                    return
//                }
//                try self.process(declarationEntity: dict, ofFile: file, fromModule: module)
//            }
////AGGRESSIVE:
//            var visited2 = Set<String>()
//            try response.recurseEntities(visited: &visited2) { [unowned self] dict in
//                if self.ignorePublic, dict.isPublic {
//                    return
//                }
//                try self.process(declarationEntity: dict, ofFile: file, fromModule: module)
//            }
            let indexedFile = IndexedFile(file: file, response: response)
            self.dataStore.indexedFiles.append(indexedFile)
        }
        dataStore.plists = dataStore.plists.union(module.plists)
    }

    func preprocess(
        declarationEntity dict: SKResponseDictionary,
        ofFile file: File,
        fromModule module: Module
    ) {
        guard let usr: String = dict[keys.usr] else {
            return
        }
        dataStore.fileForUSR[usr] = file
    }

    func process(
        declarationEntity dict: SKResponseDictionary,
        ofFile file: File,
        fromModule module: Module
    ) throws {
        let entityKind: SKUID = dict[keys.kind]!
        logger.log("DEBUG process: kind=\(entityKind.description) name=\(dict[keys.name] ?? "nil") usr=\(dict[keys.usr] ?? "nil")")
        guard let kind = entityKind.declarationType() else {
            logger.log("DEBUG SKIPPED (declarationType=nil)")
            return
        }
        guard let rawName: String = dict[keys.name],
              let usr: String = dict[keys.usr] else
        {
            return
        }

        let name = rawName.removingParameterInformation

        let isExtension = entityKind.description.contains(".decl.extension.")

        if isExtension {
            // Проверяем: это retroactive conformance? (есть key.related с ref.protocol)
            var conformedProtocolUSRs = [String]()
            if let related: SKResponseArray = dict[keys.related] {
                related.forEach(parent: dict) { (_, relDict) -> Bool in
                    if let relKind: SKUID = relDict[self.keys.kind],
                       relKind.description.contains(".ref.protocol"),
                       let relUSR: String = relDict[self.keys.usr] {
                        conformedProtocolUSRs.append(relUSR)
                    }
                    return true
                }
            }

            let extendsOurType = dataStore.declaredTypeNames.contains(name)

            if !conformedProtocolUSRs.isEmpty && !extendsOurType {
                // extension ВнешнийТип: НашПротокол — члены протокола трогать нельзя
                for protocolUSR in conformedProtocolUSRs {
                    dataStore.protocolsConformedByExternalTypes.insert(protocolUSR)
                    logger.log("* Protocol \(protocolUSR) conformed by external type \(name) — protecting members", verbose: true)
                    let toRemove = dataStore.processedUsrs.filter { $0.hasPrefix(protocolUSR) }
                    for m in toRemove {
                        dataStore.processedUsrs.remove(m)
                        logger.log("* Un-protecting \(m)", verbose: true)
                    }
                }
                // Сам extension расширяет ВНЕШНИЙ тип — его имя (UserDefaults) трогать нельзя
                logger.log("* Skipping extension declaration itself — \(name) is external type", verbose: true)
                return
            }

            // Старая логика: extension на внешний тип без conformance — пропускаем
            guard extendsOurType || !conformedProtocolUSRs.isEmpty else {
                logger.log("* Skipping extension on external type: \(name)", verbose: true)
                return
            }
        }

        if kind == .object, !isExtension {
            dataStore.declaredTypeNames.insert(name)
        }

        if namesToIgnore.contains(name) {
            logger.log("* Ignoring \(name) (USR: \(usr)) because its included in ignore-names", verbose: true)
            return
        }

        if kind == .enumelement, let parentUSR: String = dict.parent[keys.usr] {
            let codingKeysUSR: Set<String> = ["s:s9CodingKeyP"]
            if try inheritsFromAnyUSR(parentUSR, anyOf: codingKeysUSR, inModule: module) {
                logger.log("* Ignoring \(name) (USR: \(usr)) because its parent enum inherits from CodingKey.", verbose: true)
                return
            }
        }

        if kind == .property,
           dict.parent != nil,
           let parentKind: SKUID = dict.parent[keys.kind],
           parentKind.declarationType() == .object {
            guard let parentUSR: String = dict.parent[keys.usr] else {
                throw logger.fatalError(forMessage: "Parent of \(usr) is has no USR!")
            }
            let codableUSRs: Set<String> = ["s:s7Codablea", "s:SE", "s:Se"]
            if try inheritsFromAnyUSR(parentUSR, anyOf: codableUSRs, inModule: module) {
                logger.log("* Ignoring \(name) (USR: \(usr)) because its parent inherits from Codable.", verbose: true)
                return
            }
        }

        // Защита: член протокола конформленного внешним типом
        if dataStore.protocolsConformedByExternalTypes.contains(where: { usr == $0 || usr.hasPrefix($0) }) {
            logger.log("* Ignoring \(name) (USR: \(usr)) — externally-conformed protocol or its member", verbose: true)
            return
        }

        logger.log("* Found declaration of \(name) (USR: \(usr))")
        dataStore.processedUsrs.insert(usr)

        let receiver: String? = dict[keys.receiver]
        if receiver == nil {
            dataStore.usrRelationDictionary[usr] = dict
        }
    }
}

// MARK: Obfuscating

extension SourceKitObfuscator {
    @discardableResult
    func obfuscate() throws -> ConversionMap {
        try dataStore.indexedFiles.forEach { index in
            try obfuscate(index: index)
        }
        try dataStore.plists.forEach { plist in
            try obfuscate(plist: plist)
        }
        return ConversionMap(obfuscationDictionary: dataStore.obfuscationDictionary)
    }

    func obfuscate(index: IndexedFile) throws {
        logger.log("--- Obfuscating \(index.file.name)")
        var referenceArray = [Reference]()
        index.response.recurseEntities { [unowned self] dict in
            guard let kindId: SKUID = dict[self.keys.kind],
                kindId.referenceType() != nil || kindId.declarationType() != nil,
                let rawName: String = dict[self.keys.name],
                let usr: String = dict[self.keys.usr],
                self.dataStore.processedUsrs.contains(usr),
                let line: Int = dict[self.keys.line],
                let column: Int = dict[self.keys.column],
                dict.isReferencingInternalFramework(dataStore: self.dataStore) == false else {
                return
            }
            let name = rawName.removingParameterInformation
            let obfuscatedName = self.obfuscate(name: name)
            self.logger.log("* Found reference of \(name) (USR: \(usr) at \(index.file.name) (\(line):\(column)) -> now \(obfuscatedName)")
            let reference = Reference(name: name, line: line, column: column)
            referenceArray.append(reference)
        }
        let originalContents = try index.file.read()

        let emptyModule = Module(name: "", sourceFiles: [], plists: [], compilerArguments: [])
        let inheritanceRefs = collectInheritanceReferences(
            file: index.file,
            contents: originalContents,
            module: dataStore.moduleForFile[index.file.path] ?? emptyModule
        )
        referenceArray.append(contentsOf: inheritanceRefs)

        let obfuscatedContents = obfuscate(fileContents: originalContents, fromReferences: referenceArray)
        if let error = delegate?.obfuscator(self, didObfuscateFile: index.file, newContents: obfuscatedContents) {
            throw error
        }
    }

    /// Находит типы в clause наследования (class X: A, B где SourceKit
    /// index-source их не репортит) и возвращает корректные Reference
    /// через cursor-info по байтовому offset.
    func collectInheritanceReferences(
        file: File,
        contents: String,
        module: Module
    ) -> [Reference] {
        var refs = [Reference]()
        let ns = contents as NSString

        // Байтовый offset (UTF-8) начала каждой строки
        let lines = contents.components(separatedBy: "\n")
        var lineStartByte = [Int]()
        var running = 0
        for l in lines {
            lineStartByte.append(running)
            running += l.utf8.count + 1
        }

        // Находим объявления с clause наследования
        let declRegex = "(?:class|struct|enum|extension|protocol)\\s+[A-Za-z_][A-Za-z0-9_]*\\s*:\\s*[^{]+?(?:\\{|\\bwhere\\b)"
        let declMatches = contents.match(regex: declRegex)
        logger.log("* [inheritance-debug] \(file.name): found \(declMatches.count) decl-clauses")

        for declMatch in declMatches {
            let declRange = declMatch.range // NSRange в UTF-16
            let declStr = ns.substring(with: declRange)
            logger.log("* [inheritance-debug] clause: \(declStr.prefix(80))")

            // позиция ":" внутри declStr (в UTF-16)
            let declNS = declStr as NSString
            let colonNSRange = declNS.range(of: ":")
            guard colonNSRange.location != NSNotFound else { continue }

            // clause = всё после ":" внутри declStr
            let clauseStartInDecl = colonNSRange.location + colonNSRange.length
            let clauseLen = declNS.length - clauseStartInDecl
            guard clauseLen > 0 else { continue }
            let clauseStr = declNS.substring(with: NSRange(location: clauseStartInDecl, length: clauseLen))

            // идентификаторы в clause
            let identMatches = clauseStr.match(regex: "[A-Za-z_][A-Za-z0-9_]*")
            for idm in identMatches {
                let ident = clauseStr as NSString
                let identStr = ident.substring(with: idm.range)
                if identStr == "where" { continue }

                // глобальный UTF-16 offset идентификатора в contents
                let globalUTF16 = declRange.location + clauseStartInDecl + idm.range.location

                // конвертируем UTF-16 offset -> (line0, columnUTF16)
                let prefix = ns.substring(to: globalUTF16)
                let prefixLines = prefix.components(separatedBy: "\n")
                let lineIndex = prefixLines.count - 1
                let columnUTF16 = (prefixLines.last as NSString?)?.length ?? 0

                guard lineIndex < lines.count else { continue }
                let lineText = lines[lineIndex]
                let lineNS = lineText as NSString

                // байты до идентификатора в этой строке
                let beforeIdent = lineNS.substring(to: min(columnUTF16, lineNS.length))
                let bytesBefore = beforeIdent.utf8.count
                let byteOffset = lineStartByte[lineIndex] + bytesBefore

                guard let usr = usrViaCursorInfo(file: file, byteOffset: byteOffset, module: module) else {
                    logger.log("* [inheritance-debug] \(identStr): cursor-info returned NIL at byteOffset \(byteOffset)")
                    continue
                }
                logger.log("* [inheritance-debug] \(identStr): got USR \(usr), inProcessed=\(dataStore.processedUsrs.contains(usr))")
                guard dataStore.processedUsrs.contains(usr) else { continue }

                // column 1-based — в символах (как обычно у SwiftShield)
                // SwiftShield обфускатор считает column по utf8Count, поэтому считаем так же
                let columnBytes = bytesBefore + 1

                logger.log("* [inheritance] \(identStr) (USR: \(usr)) at \(file.name) (\(lineIndex + 1):\(columnBytes))")
                refs.append(Reference(name: identStr, line: lineIndex + 1, column: columnBytes))
            }
        }
        return refs
    }

    func obfuscate(plist: File) throws {
        var data = try plist.read()
        let regex = "\\$\\(PRODUCT_MODULE_NAME\\)\\.[^ \n]*<"
        let results = data.match(regex: regex)
        guard results.isEmpty == false else {
            return
        }
        logger.log("--- Obfuscating \(plist.name)")
        for result in results.reversed() {
            let value = String(result.captureGroup(0, originalString: data).dropLast())
            let range = result.captureGroupRange(0, originalString: data)
            let productModuleName = "$(PRODUCT_MODULE_NAME)"
            let currentName = value.components(separatedBy: "\(productModuleName).").last ?? ""
            let protectedName = dataStore.obfuscationDictionary[currentName] ?? currentName
            let newPlistValue = productModuleName + "." + protectedName + "<"
            data = data.replacingCharacters(in: range, with: newPlistValue)
        }
        let newPlist = data
        if let error = delegate?.obfuscator(self, didObfuscateFile: plist, newContents: newPlist) {
            throw error
        }
    }

    func obfuscate(name: String) -> String {
        let cachedResult = dataStore.obfuscationDictionary[name]
        guard cachedResult == nil else {
            return cachedResult!
        }
        let size = 32
        let letters: [Character] = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let numbers: [Character] = Array("0123456789")
        let lettersAndNumbers = letters + numbers
        var randomString = ""
        for i in 0 ..< size {
            let characters: [Character] = i == 0 ? letters : lettersAndNumbers
            let rand = Int.random(in: 0 ..< characters.count)
            let nextChar = characters[rand]
            randomString.append(nextChar)
        }
        guard dataStore.obfuscatedNames.contains(randomString) == false else {
            return obfuscate(name: name)
        }
        dataStore.obfuscatedNames.insert(randomString)
        dataStore.obfuscationDictionary[name] = randomString
        return randomString
    }

    func obfuscate(fileContents: String, fromReferences references: [Reference]) -> String {
        let sortedReferences = references.sorted(by: <)

        var previousReference: Reference!
        var currentReferenceIndex = 0
        var line = 1
        var column = 1
        var currentCharIndex = 0

        var charArray: [String] = Array(fileContents).map(String.init)

        while currentCharIndex < charArray.count, currentReferenceIndex < sortedReferences.count {
            let reference = sortedReferences[currentReferenceIndex]
            if previousReference != nil,
                reference.line == previousReference.line,
                reference.column == previousReference.column {
                // Avoid duplicates.
                currentReferenceIndex += 1
            }
            let currentCharacter = charArray[currentCharIndex]
            if line == reference.line, column == reference.column {
                previousReference = reference
                let originalName = reference.name
                let obfuscatedName = obfuscate(name: originalName)
                let wasInternalKeyword = currentCharacter == "`"
                let startIndex = currentCharIndex + (wasInternalKeyword ? 1 : 0)

                // Считаем реальную длину идентификатора в файле
                var actualLength = 0
                while startIndex + actualLength < charArray.count {
                    let ch = charArray[startIndex + actualLength]
                    guard ch.count == 1,
                          let scalar = ch.unicodeScalars.first,
                          CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains(scalar) else { break }
                    actualLength += 1
                }
                let totalLength = actualLength + (wasInternalKeyword ? 2 : 0)

                for i in 1 ..< max(1, totalLength) {
                    charArray[currentCharIndex + i] = ""
                }
                charArray[currentCharIndex] = obfuscatedName
                currentReferenceIndex += 1
                currentCharIndex += max(1, totalLength - (wasInternalKeyword ? 1 : 0))
                column += totalLength
                if wasInternalKeyword {
                    charArray[currentCharIndex] = ""
                }
            } else if currentCharacter == "\n" {
                line += 1
                column = 1
                currentCharIndex += 1
            } else {
                column += currentCharacter.utf8Count
                currentCharIndex += 1
            }
        }
        return charArray.joined()
    }
}

extension SourceKitObfuscator {
    func inheritsFromAnyUSR(_ usr: String, anyOf usrs: Set<String>, inModule module: Module) throws -> Bool {
        let usrsKey = usrs.joined(separator: " ")
        if let cache = dataStore.inheritsFromX[usr, default: [:]][usrsKey] {
            return cache
        }

        func result(_ val: Bool) -> Bool {
            dataStore.inheritsFromX[usr, default: [:]][usrsKey] = val
            return val
        }

        // cycles flag = false while counting
        dataStore.inheritsFromX[usr, default: [:]][usrsKey] = false

        let req = SKRequestDictionary(sourcekitd: sourceKit)
        req[keys.request] = requests.cursorinfo
        req[keys.usr] = usr
        let file: File = dataStore.fileForUSR[usr] ?? module.sourceFiles.first!
        let correctModule = dataStore.moduleForFile[file.path] ?? module
        req[keys.sourcefile] = file.path
        req[keys.compilerargs] = correctModule.compilerArguments
        let cursorInfo = try sourceKit.sendSync(req)
        guard let annotation: String = cursorInfo[keys.annotated_decl] else {
            logger.log("Pretending \(usr) inherits from Codable because SourceKit failed to look it up. This can happen if this USR belongs to an @objc class.", verbose: true)
            return result(true)
        }
        let regex = "usr=\\\"(.\\S*)\\\""
        let regexResult = annotation.match(regex: regex)
        for res in regexResult {
            let inheritedUSR = res.captureGroup(1, originalString: annotation)
            if usrs.contains(inheritedUSR) {
                return result(true)
            } else if try inheritsFromAnyUSR(inheritedUSR, anyOf: usrs, inModule: module) {
                return result(true)
            }
        }
        return result(false)
    }
//    func inheritsFromAnyUSR(_ usr: String, anyOf usrs: Set<String>, inModule module: Module) throws -> Bool {
//        let usrsKey = usrs.joined(separator: " ")
//        if let cache = dataStore.inheritsFromX[usr, default: [:]][usrsKey] {
//            return cache
//        }
//
//        func result(_ val: Bool) -> Bool {
//            dataStore.inheritsFromX[usr, default: [:]][usrsKey] = val
//            return val
//        }
//
//        let req = SKRequestDictionary(sourcekitd: sourceKit)
//        req[keys.request] = requests.cursorinfo
//        req[keys.compilerargs] = module.compilerArguments
//        req[keys.usr] = usr
//        // We have to store the file of the USR because it looks CursorInfo doesn't returns USRs if you use the wrong one
//        //, except if it's a closed source framework. No idea why it works like that.
//        // Hopefully this won't break in the future.
//        let file: File = dataStore.fileForUSR[usr] ?? module.sourceFiles.first!
//        req[keys.sourcefile] = file.path
//        let cursorInfo = try sourceKit.sendSync(req)
//        guard let annotation: String = cursorInfo[keys.annotated_decl] else {
//            logger.log("Pretending \(usr) inherits from Codable because SourceKit failed to look it up. This can happen if this USR belongs to an @objc class.", verbose: true)
//            return result(true)
//        }
//        let regex = "usr=\\\"(.\\S*)\\\""
//        let regexResult = annotation.match(regex: regex)
//        for res in regexResult {
//            let inheritedUSR = res.captureGroup(1, originalString: annotation)
//            if usrs.contains(inheritedUSR) {
//                return result(true)
//            } else if try inheritsFromAnyUSR(inheritedUSR, anyOf: usrs, inModule: module) {
//                return result(true)
//            }
//        }
//        return result(false)
//    }
    /// Запрашивает USR символа на конкретной байтовой позиции в файле.
    /// Используется для типов в clause наследования, которые index-source не репортит.
    func usrViaCursorInfo(file: File, byteOffset: Int, module: Module) -> String? {
        let req = SKRequestDictionary(sourcekitd: sourceKit)
        req[keys.request] = requests.cursorinfo
        req[keys.offset] = byteOffset
        let correctModule = dataStore.moduleForFile[file.path] ?? module
        req[keys.sourcefile] = file.path
        req[keys.compilerargs] = correctModule.compilerArguments
        guard let resp = try? sourceKit.sendSync(req) else { return nil }
        let usr: String? = resp[keys.usr]
        return usr
    }
}

// MARK: SKResponseDictionary Helpers

extension SKResponseDictionary {
    var isPublic: Bool {
        if let kindId: SKUID = self[sourcekitd.keys.kind], let type = kindId.declarationType(), type == .enumelement {
            return parent.isPublic
        }
        guard let attributes: SKResponseArray = self[sourcekitd.keys.attributes] else {
            return false
        }
        guard attributes.count > 0 else {
            return false
        }
        for i in 0 ..< attributes.count {
            guard let attr: SKUID = attributes[i][sourcekitd.keys.attribute] else {
                continue
            }
            guard attr.asString == AccessControl.public.rawValue || attr.asString == AccessControl.open.rawValue else {
                continue
            }
            return true
        }
        return false
    }

    func isReferencingInternalFramework(dataStore: SourceKitObfuscatorDataStore) -> Bool {
        guard let kindId: SKUID = self[sourcekitd.keys.kind] else {
            return false
        }
        let type = kindId.referenceType() ?? kindId.declarationType()
        guard type == .method || type == .property else {
            return false
        }
        guard let usr: String = self[sourcekitd.keys.usr] else {
            return false
        }
        let usrRelationDict = dataStore.usrRelationDictionary
        if let dict: SKResponseDictionary = usrRelationDict[usr], self.dict.data != dict.dict.data {
            return dict.isReferencingInternalFramework(dataStore: dataStore)
        }
        var isReference = false
        recurse(uid: sourcekitd.keys.related) { [unowned self] dict in
            guard isReference == false else {
                return
//        var visited4 = Set<String>()
//        recurse(uid: sourcekitd.keys.related, visited: &visited4) { [unowned self] dict in
//            guard isReference == false else {
//                return
            }
            guard let usr: String = dict[self.sourcekitd.keys.usr] else {
                return
            }
            if dataStore.processedUsrs.contains(usr) == false {
                isReference = true
            } else if let dict: SKResponseDictionary = usrRelationDict[usr] {
                isReference = dict.isReferencingInternalFramework(dataStore: dataStore)
            }
        }
        return isReference
    }
}
