package com.oguzhnatly.flutter_android_auto

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class FAATabBarTemplateTest {
    @Test
    fun `rejects an invalid selectable list in a non-active tab`() {
        val exception = assertThrows(IllegalArgumentException::class.java) {
            FAATabBarTemplate.fromJson(
                mapOf(
                    "_elementId" to "tabs",
                    "tabs" to listOf(
                        listTab("first", listOf(listSection())),
                        listTab(
                            "invalid",
                            listOf(
                                listSection(
                                    title = "Options",
                                    selectedIndex = 0,
                                ),
                            ),
                        ),
                    ),
                ),
            )
        }

        assertEquals(
            "A selectable AAListSection must be the only section in an AAListTemplate and must not have a title.",
            exception.message,
        )
    }

    private fun listTab(id: String, sections: List<Map<String, Any?>>) = mapOf(
        "elementId" to id,
        "runtimeType" to "FAAListTemplate",
        "template" to mapOf(
            "_elementId" to id,
            "title" to id,
            "sections" to sections,
        ),
    )

    private fun listSection(
        title: String = "",
        selectedIndex: Int? = null,
    ) = mapOf(
        "_elementId" to "section-$title",
        "title" to title,
        "selectedIndex" to selectedIndex,
        "items" to listOf(
            mapOf(
                "_elementId" to "item-$title",
                "title" to "Item",
            ),
        ),
    )
}
