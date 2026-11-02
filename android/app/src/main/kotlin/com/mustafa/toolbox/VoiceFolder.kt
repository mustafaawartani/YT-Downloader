package com.mustafa.toolbox

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract

/** Lists audio files in WhatsApp's "Voice Notes" folder (picked once with the system folder picker). */
object VoiceFolder {
    private val AUDIO_EXT = setOf("opus", "ogg", "oga", "m4a", "aac", "mp3", "amr", "wav", "3gp")

    private const val VOICE_NOTES_DOC_ID =
        "primary:Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Voice Notes"

    /** Where the picker opens, so the user only has to tap "Use this folder". */
    fun initialUri(): Uri =
        DocumentsContract.buildDocumentUri("com.android.externalstorage.documents", VOICE_NOTES_DOC_ID)

    fun list(context: Context, tree: Uri): List<Map<String, Any>> {
        val result = mutableListOf<Map<String, Any>>()
        val resolver = context.contentResolver
        val columns = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            DocumentsContract.Document.COLUMN_SIZE,
        )

        fun walk(docId: String, depth: Int) {
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, docId)
            resolver.query(children, columns, null, null, null)?.use { c ->
                while (c.moveToNext()) {
                    val id = c.getString(0)
                    val name = c.getString(1) ?: continue
                    if (c.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR) {
                        if (depth < 4 && shouldDescend(name)) walk(id, depth + 1)
                    } else if (name.substringAfterLast('.', "").lowercase() in AUDIO_EXT) {
                        result += mapOf(
                            "uri" to DocumentsContract.buildDocumentUriUsingTree(tree, id).toString(),
                            "name" to name,
                            "modified" to c.getLong(3),
                            "size" to c.getLong(4),
                        )
                    }
                }
            }
        }

        walk(DocumentsContract.getTreeDocumentId(tree), 0)
        return result
    }

    private fun shouldDescend(name: String): Boolean =
        !name.startsWith(".") && (
            name.all { it.isDigit() } || name.contains("Voice", ignoreCase = true) ||
                name in setOf("WhatsApp", "WhatsApp Business", "Media", "Sent")
            )
}
