#!/bin/bash

# Create project structure
mkdir -p fixparser/src/main/kotlin/com/lgweida/fixparser/{config,controller,service,model,utils}
mkdir -p fixparser/src/test/kotlin/com/lgweida/fixparser
touch fixparser/build.gradle.kts
touch fixparser/settings.gradle.kts

# Create build.gradle.kts
cat > fixparser/build.gradle.kts << 'EOF'
plugins {
    id("org.springframework.boot") version "3.2.0"
    id("io.spring.dependency-management") version "1.1.4"
    kotlin("jvm") version "1.9.20"
    kotlin("plugin.spring") version "1.9.20"
    id("org.springdoc.openapi-gradle-plugin") version "1.8.0"
}

group = "com.lgweida"
version = "1.0.0"

dependencies {
    implementation("org.springframework.boot:spring-boot-starter-web")
    implementation("org.springframework.boot:spring-boot-starter-cache")
    implementation("com.fasterxml.jackson.module:jackson-module-kotlin")
    implementation("org.jetbrains.kotlin:kotlin-reflect")
    implementation("org.quickfixj:quickfixj-all:2.3.1")
    implementation("org.springdoc:springdoc-openapi-starter-webmvc-ui:2.3.0")
    implementation("com.github.ben-manes.caffeine:caffeine:3.1.8")
    testImplementation("org.springframework.boot:spring-boot-starter-test")
}

tasks.withType<Test> {
    useJUnitPlatform()
}
EOF

# Create settings.gradle.kts
cat > fixparser/settings.gradle.kts << 'EOF'
rootProject.name = "fixparser"
EOF

# Create Application.kt
cat > fixparser/src/main/kotlin/com/lgweida/fixparser/FixParserApplication.kt << 'EOF'
package com.lgweida.fixparser

import org.springframework.boot.autoconfigure.SpringBootApplication
import org.springframework.boot.runApplication
import org.springframework.cache.annotation.EnableCaching

@SpringBootApplication
@EnableCaching
class FixParserApplication

fun main(args: Array<String>) {
    runApplication<FixParserApplication>(*args)
}
EOF

# Create model files
cat > fixparser/src/main/kotlin/com/lgweida/fixparser/model/FixParseRequest.kt << 'EOF'
package com.lgweida.fixparser.model

data class FixParseRequest(
    val messages: List<String>
)
EOF

cat > fixparser/src/main/kotlin/com/lgweida/fixparser/model/ParsedField.kt << 'EOF'
package com.lgweida.fixparser.model

data class ParsedField(
    val tag: Int,
    val name: String,
    val value: String,
    val description: String? = null,
    val isInGroup: Boolean = false,
    val groupId: Int? = null
)
EOF

cat > fixparser/src/main/kotlin/com/lgweida/fixparser/model/ParsedMessage.kt << 'EOF'
package com.lgweida.fixparser.model

data class ParsedMessage(
    val messageType: String,
    val header: List<ParsedField>,
    val body: List<ParsedField>,
    val trailer: List<ParsedField>,
    val otherFields: List<ParsedField>,
    val repeatingGroups: Map<String, List<List<ParsedField>>>,
    val isValid: Boolean,
    val validationErrors: List<String> = emptyList()
)
EOF

cat > fixparser/src/main/kotlin/com/lgweida/fixparser/model/FixParseResponse.kt << 'EOF'
package com.lgweida.fixparser.model

data class FixParseResponse(
    val results: List<ParsedMessage>
)
EOF

# Create service files
cat > fixparser/src/main/kotlin/com/lgweida/fixparser/service/FixParserService.kt << 'EOF'
package com.lgweida.fixparser.service

import com.lgweida.fixparser.model.*
import org.springframework.cache.annotation.Cacheable
import org.springframework.stereotype.Service
import quickfix.*
import quickfix.field.*
import java.util.*
import javax.validation.ValidationException

@Service
class FixParserService(private val fixDataDictionary: FixDataDictionary) {

    @Cacheable("parsedMessages")
    fun parseMessages(rawMessages: List<String>): FixParseResponse {
        val results = rawMessages.mapNotNull { rawMessage ->
            try {
                parseSingleMessage(rawMessage)
            } catch (e: Exception) {
                ParsedMessage(
                    messageType = "ERROR",
                    header = emptyList(),
                    body = emptyList(),
                    trailer = emptyList(),
                    otherFields = emptyList(),
                    repeatingGroups = emptyMap(),
                    isValid = false,
                    validationErrors = listOf("Failed to parse message: ${e.message}")
                )
            }
        }
        return FixParseResponse(results)
    }

    private fun parseSingleMessage(rawMessage: String): ParsedMessage {
        val normalizedMessage = rawMessage.replace('|', '\u0001')
        val message = MessageUtils.parse(DefaultMessageFactory(), null, normalizedMessage)
        
        // Validate checksum
        val validationErrors = mutableListOf<String>()
        if (!fixDataDictionary.validateChecksum(message)) {
            validationErrors.add("Invalid checksum")
        }

        val messageType = message.getHeader().getString(MsgType.FIELD)
        val messageTypeName = fixDataDictionary.getMessageTypeName(messageType)

        val (headerFields, headerGroups) = fixDataDictionary.parseFieldSection(message.header, true)
        val (bodyFields, bodyGroups) = fixDataDictionary.parseFieldSection(message, false)
        val (trailerFields, trailerGroups) = fixDataDictionary.parseFieldSection(message.trailer, true)
        val otherFields = fixDataDictionary.parseOtherFields(message)

        val allGroups = headerGroups + bodyGroups + trailerGroups

        return ParsedMessage(
            messageType = messageTypeName,
            header = headerFields,
            body = bodyFields,
            trailer = trailerFields,
            otherFields = otherFields,
            repeatingGroups = allGroups,
            isValid = validationErrors.isEmpty(),
            validationErrors = validationErrors
        )
    }
}
EOF

cat > fixparser/src/main/kotlin/com/lgweida/fixparser/service/FixDataDictionary.kt << 'EOF'
package com.lgweida.fixparser.service

import com.lgweida.fixparser.model.ParsedField
import quickfix.*
import quickfix.field.*
import java.util.*
import javax.annotation.PostConstruct

@Service
class FixDataDictionary {

    private lateinit var messageTypes: Map<String, String>
    private lateinit var fieldDefinitions: Map<Int, FieldDefinition>
    private lateinit var repeatingGroups: Map<String, Map<Int, FieldDefinition>>

    @PostConstruct
    fun initialize() {
        // Initialize all FIX 4.4 definitions
        messageTypes = mapOf(
            MsgType.ORDER_SINGLE to "New Order - Single",
            MsgType.EXECUTION_REPORT to "Execution Report",
            MsgType.ORDER_CANCEL_REQUEST to "Order Cancel Request",
            MsgType.ORDER_CANCEL_REPLACE_REQUEST to "Order Cancel/Replace Request",
            MsgType.ORDER_STATUS_REQUEST to "Order Status Request",
            MsgType.ALLOCATION_INSTRUCTION to "Allocation Instruction",
            MsgType.LIST_CANCEL_REQUEST to "List Cancel Request",
            MsgType.LIST_EXECUTE to "List Execute",
            MsgType.LIST_STATUS_REQUEST to "List Status Request",
            MsgType.LIST_STATUS to "List Status",
            MsgType.ALLOCATION_INSTRUCTION_ACK to "Allocation Instruction Ack",
            MsgType.DONT_KNOW_TRADE to "Don't Know Trade",
            MsgType.QUOTE_REQUEST to "Quote Request",
            MsgType.QUOTE to "Quote",
            MsgType.SETTLEMENT_INSTRUCTIONS to "Settlement Instructions",
            MsgType.MARKET_DATA_REQUEST to "Market Data Request",
            MsgType.MARKET_DATA_SNAPSHOT_FULL_REFRESH to "Market Data Snapshot/Full Refresh",
            MsgType.MARKET_DATA_INCREMENTAL_REFRESH to "Market Data Incremental Refresh",
            MsgType.MARKET_DATA_REQUEST_REJECT to "Market Data Request Reject",
            MsgType.QUOTE_CANCEL to "Quote Cancel",
            MsgType.QUOTE_STATUS_REQUEST to "Quote Status Request",
            MsgType.MASS_QUOTE_ACKNOWLEDGEMENT to "Mass Quote Acknowledgement",
            MsgType.SECURITY_DEFINITION_REQUEST to "Security Definition Request",
            MsgType.SECURITY_DEFINITION to "Security Definition",
            MsgType.SECURITY_STATUS_REQUEST to "Security Status Request",
            MsgType.SECURITY_STATUS to "Security Status",
            MsgType.TRADING_SESSION_STATUS_REQUEST to "Trading Session Status Request",
            MsgType.TRADING_SESSION_STATUS to "Trading Session Status",
            MsgType.MASS_QUOTE to "Mass Quote",
            MsgType.BUSINESS_MESSAGE_REJECT to "Business Message Reject",
            MsgType.QUOTE_REQUEST_REJECT to "Quote Request Reject",
            MsgType.RFQ_REQUEST to "Request for Quote",
            MsgType.QUOTE_STATUS_REPORT to "Quote Status Report",
            MsgType.QUOTE_RESPONSE to "Quote Response"
        )

        fieldDefinitions = mapOf(
            // Header fields
            BeginString.FIELD to FieldDefinition("BeginString"),
            BodyLength.FIELD to FieldDefinition("BodyLength"),
            MsgType.FIELD to FieldDefinition("MsgType", messageTypes),
            SenderCompID.FIELD to FieldDefinition("SenderCompID"),
            TargetCompID.FIELD to FieldDefinition("TargetCompID"),
            MsgSeqNum.FIELD to FieldDefinition("MsgSeqNum"),
            SendingTime.FIELD to FieldDefinition("SendingTime"),
            // ... add all other FIX 4.4 fields
            // Trailer field
            CheckSum.FIELD to FieldDefinition("CheckSum")
        )

        repeatingGroups = mapOf(
            "NoPartyIDs" to mapOf(
                PartyID.FIELD to FieldDefinition("PartyID"),
                PartyIDSource.FIELD to FieldDefinition("PartyIDSource"),
                PartyRole.FIELD to FieldDefinition("PartyRole")
            ),
            "NoAllocs" to mapOf(
                AllocAccount.FIELD to FieldDefinition("AllocAccount"),
                AllocPrice.FIELD to FieldDefinition("AllocPrice"),
                AllocQty.FIELD to FieldDefinition("AllocQty")
            )
            // ... add other repeating groups
        )
    }

    fun getMessageTypeName(messageType: String): String {
        return messageTypes[messageType] ?: "Unknown ($messageType)"
    }

    fun parseFieldSection(fieldMap: FieldMap, isHeaderOrTrailer: Boolean): Pair<List<ParsedField>, Map<String, List<List<ParsedField>>>> {
        val fields = mutableListOf<ParsedField>()
        val groups = mutableMapOf<String, List<List<ParsedField>>>()
        val iterator = fieldMap.iterator()

        while (iterator.hasNext()) {
            val field = iterator.next()
            val tag = field.tag
            val value = field.value

            if (fieldDefinitions.containsKey(tag)) {
                val fieldDef = fieldDefinitions[tag]!!
                fields.add(ParsedField(
                    tag = tag,
                    name = fieldDef.name,
                    value = value,
                    description = fieldDef.getDescription(value)
                ))
            } else if (repeatingGroups.containsKey(fieldDefinitions[tag]?.name)) {
                // Handle repeating groups
                val groupName = fieldDefinitions[tag]?.name!!
                val groupDef = repeatingGroups[groupName]!!
                val groupInstances = parseRepeatingGroup(fieldMap, tag, groupDef)
                groups[groupName] = groupInstances
            }
        }

        return Pair(fields, groups)
    }

    private fun parseRepeatingGroup(fieldMap: FieldMap, groupTag: Int, groupDef: Map<Int, FieldDefinition>): List<List<ParsedField>> {
        val groupInstances = mutableListOf<List<ParsedField>>()
        try {
            val groupCount = fieldMap.getInt(groupTag)
            for (i in 1..groupCount) {
                val groupFields = mutableListOf<ParsedField>()
                for ((tag, fieldDef) in groupDef) {
                    val fieldValue = fieldMap.getString(tag, i)
                    groupFields.add(ParsedField(
                        tag = tag,
                        name = fieldDef.name,
                        value = fieldValue,
                        description = fieldDef.getDescription(fieldValue),
                        isInGroup = true,
                        groupId = groupTag
                    ))
                }
                groupInstances.add(groupFields)
            }
        } catch (e: FieldNotFound) {
            // Group not found
        }
        return groupInstances
    }

    fun parseOtherFields(message: Message): List<ParsedField> {
        val fields = mutableListOf<ParsedField>()
        val iterator = message.iterator()
        
        while (iterator.hasNext()) {
            val field = iterator.next()
            if (!fieldDefinitions.containsKey(field.tag)) {
                fields.add(ParsedField(
                    tag = field.tag,
                    name = "Tag ${field.tag}",
                    value = field.value
                ))
            }
        }
        
        return fields
    }

    fun validateChecksum(message: Message): Boolean {
        try {
            val checksum = message.getTrailer().getString(CheckSum.FIELD)
            val calculatedChecksum = MessageUtils.checksum(message.toString())
            return checksum == calculatedChecksum
        } catch (e: Exception) {
            return false
        }
    }

    data class FieldDefinition(
        val name: String,
        val valueDescriptions: Map<String, String>? = null
    ) {
        fun getDescription(value: String): String? {
            return valueDescriptions?.get(value)
        }
    }
}
EOF

# Create controller
cat > fixparser/src/main/kotlin/com/lgweida/fixparser/controller/FixParserController.kt << 'EOF'
package com.lgweida.fixparser.controller

import com.lgweida.fixparser.model.*
import com.lgweida.fixparser.service.FixParserService
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.media.Content
import io.swagger.v3.oas.annotations.media.Schema
import io.swagger.v3.oas.annotations.responses.ApiResponse
import io.swagger.v3.oas.annotations.tags.Tag
import org.springframework.web.bind.annotation.*

@RestController
@RequestMapping("/api/fix")
@Tag(name = "FIX Parser", description = "API for parsing FIX messages")
class FixParserController(private val fixParserService: FixParserService) {

    @PostMapping("/parse")
    @Operation(
        summary = "Parse FIX messages",
        description = "Parse one or more FIX messages in JSON format",
        responses = [
            ApiResponse(
                responseCode = "200",
                description = "Successfully parsed messages",
                content = [Content(schema = Schema(implementation = FixParseResponse::class))]
            )
        ]
    )
    fun parseFixMessages(@RequestBody request: FixParseRequest): FixParseResponse {
        return fixParserService.parseMessages(request.messages)
    }

    @PostMapping("/parse/text")
    @Operation(
        summary = "Parse raw FIX text",
        description = "Parse raw FIX message text (one message per line)",
        responses = [
            ApiResponse(
                responseCode = "200",
                description = "Successfully parsed messages",
                content = [Content(schema = Schema(implementation = FixParseResponse::class))]
            )
        ]
    )
    fun parseFixText(@RequestBody text: String): FixParseResponse {
        val messages = text.lines()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
        return fixParserService.parseMessages(messages)
    }
}
EOF

# Create Swagger config
cat > fixparser/src/main/kotlin/com/lgweida/fixparser/config/SwaggerConfig.kt << 'EOF'
package com.lgweida.fixparser.config

import io.swagger.v3.oas.models.OpenAPI
import io.swagger.v3.oas.models.info.Info
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration

@Configuration
class SwaggerConfig {
    @Bean
    fun customOpenAPI(): OpenAPI {
        return OpenAPI()
            .info(Info()
                .title("FIX Parser API")
                .version("1.0")
                .description("API for parsing FIX 4.4 messages"))
    }
}
EOF

# Create cache config
cat > fixparser/src/main/kotlin/com/lgweida/fixparser/config/CacheConfig.kt << 'EOF'
package com.lgweida.fixparser.config

import org.springframework.cache.annotation.EnableCaching
import org.springframework.context.annotation.Configuration

@Configuration
@EnableCaching
class CacheConfig
EOF

echo "Project structure created successfully."
echo "To build and run the project:"
echo "cd fixparser && ./gradlew bootRun"