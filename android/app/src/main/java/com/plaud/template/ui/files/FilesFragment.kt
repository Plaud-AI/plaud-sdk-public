package com.plaud.template.ui.files

import android.content.Intent
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.fragment.app.Fragment
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.plaud.template.PlaudTemplateApp
import com.plaud.template.R
import com.plaud.template.databinding.FragmentFilesBinding
import com.plaud.template.models.RecordingFile
import com.plaud.template.models.SyncProgress
import com.plaud.template.models.SyncState
import com.plaud.template.storage.RecordingStore
import com.plaud.template.ui.filedetail.FileDetailActivity
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.*

/**
 * Files Tab — File list grouped by date + Sync Banner
 */
class FilesFragment : Fragment() {

    private var _binding: FragmentFilesBinding? = null
    private val binding get() = _binding!!

    private val app get() = requireActivity().application as PlaudTemplateApp
    private val syncManager get() = app.syncManager

    private val adapter = FilesAdapter { file ->
        val intent = Intent(requireContext(), FileDetailActivity::class.java)
        intent.putExtra("file_id", file.id)
        startActivity(intent)
    }

    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View {
        _binding = FragmentFilesBinding.inflate(inflater, container, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)

        binding.filesRecyclerView.layoutManager = LinearLayoutManager(requireContext())
        binding.filesRecyclerView.adapter = adapter

        binding.searchButton.setOnClickListener { /* Search placeholder */ }

        binding.syncBanner.fastTransferButton.setOnClickListener {
            if (RecordingStore.fastTransferNeverShowAgain) {
                syncManager.startWiFiTransfer()
            } else {
                com.plaud.template.ui.home.FastTransferSheet()
                    .show(childFragmentManager, "FastTransferSheet")
            }
        }

        observeManagers()
    }

    private fun observeManagers() {
        viewLifecycleOwner.lifecycleScope.launch {
            viewLifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                launch {
                    syncManager.files.collect { files ->
                        adapter.submitFiles(files)
                        binding.emptyLabel.visibility = if (files.isEmpty()) View.VISIBLE else View.GONE
                        binding.filesRecyclerView.visibility = if (files.isEmpty()) View.GONE else View.VISIBLE
                    }
                }

                launch {
                    syncManager.state.collect { state ->
                        updateSyncBanner(state)
                    }
                }
            }
        }
    }

    private fun updateSyncBanner(state: SyncState) {
        val bannerRoot = binding.syncBanner.root
        when (state) {
            is SyncState.Syncing -> {
                fadeInBanner(bannerRoot)
                updateBannerContent(state.progress, false)
            }
            is SyncState.WiFiTransferring -> {
                fadeInBanner(bannerRoot)
                updateBannerContent(state.progress, true)
            }
            // Keep the banner untouched during the WiFi connect window (mirrors iOS)
            is SyncState.WiFiConnecting -> {}
            is SyncState.Completed -> {
                bannerRoot.postDelayed({ fadeOutBanner(bannerRoot) }, 2000)
            }
            else -> fadeOutBanner(bannerRoot)
        }
    }

    /// 0.25s fade in/out (mirrors iOS banner animations).
    private fun fadeInBanner(v: View) {
        if (v.visibility == View.VISIBLE && v.alpha == 1f) return
        v.alpha = if (v.visibility == View.VISIBLE) v.alpha else 0f
        v.visibility = View.VISIBLE
        v.animate().alpha(1f).setDuration(250).start()
    }

    private fun fadeOutBanner(v: View) {
        if (v.visibility != View.VISIBLE) return
        v.animate().alpha(0f).setDuration(250)
            .withEndAction { v.visibility = View.GONE; v.alpha = 1f }
            .start()
    }

    private fun updateBannerContent(progress: SyncProgress, isWiFi: Boolean) {
        val banner = binding.syncBanner
        banner.syncTitleLabel.text =
            if (isWiFi) getString(R.string.fast_transfer) else getString(R.string.syncing_recordings)
        banner.syncCountLabel.text =
            if (progress.totalFiles > 0) "${progress.syncedFiles}/${progress.totalFiles}" else ""

        val fill = banner.syncProgressFill
        fill.post {
            val parent = fill.parent as? View ?: return@post
            val fraction = progress.progressFraction.coerceIn(0f, 1f)
            fill.layoutParams = fill.layoutParams.apply {
                width = (parent.width * fraction).toInt().coerceAtLeast(1)
            }
        }

        // Always show progress as a percentage so the readout never flickers between a speed and
        // a (usually "Untitled") file name; append the real transfer speed when one is reported.
        val percent = (progress.progressFraction.coerceIn(0f, 1f) * 100).toInt()
        banner.syncSpeedLabel.text = when {
            progress.totalFiles == 0 -> getString(R.string.retrieving_file_list)
            progress.bytesPerSecond > 0 -> "$percent% · ${progress.speedText}"
            else -> "$percent%"
        }

        banner.fastTransferButton.visibility =
            if (isWiFi) View.GONE else View.VISIBLE
    }

    override fun onDestroyView() {
        super.onDestroyView()
        _binding = null
    }
}

// MARK: - RecyclerView Adapter

/**
 * File list adapter, supports date group headers
 */
class FilesAdapter(
    private val onFileTapped: (RecordingFile) -> Unit
) : RecyclerView.Adapter<RecyclerView.ViewHolder>() {

    companion object {
        private const val TYPE_HEADER = 0
        private const val TYPE_FILE = 1
    }

    private sealed class ListItem {
        data class Header(val title: String) : ListItem()
        data class FileItem(val file: RecordingFile) : ListItem()
    }

    private var items = listOf<ListItem>()

    fun submitFiles(files: List<RecordingFile>) {
        val sorted = files.sortedByDescending { it.createdAt }
        val grouped = mutableListOf<ListItem>()
        var lastDateKey = ""
        val today = Calendar.getInstance()
        val yesterday = Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, -1) }
        val dateFormat = SimpleDateFormat("EEE, MMM d", Locale.getDefault())
        val dayFormat = SimpleDateFormat("yyyyMMdd", Locale.getDefault())

        for (file in sorted) {
            val fileDate = Date(file.createdAt)
            val dateKey = dayFormat.format(fileDate)
            if (dateKey != lastDateKey) {
                lastDateKey = dateKey
                val cal = Calendar.getInstance().apply { time = fileDate }
                val title = when {
                    dayFormat.format(today.time) == dateKey -> "Today"
                    dayFormat.format(yesterday.time) == dateKey -> "Yesterday"
                    else -> dateFormat.format(fileDate)
                }
                grouped.add(ListItem.Header(title))
            }
            grouped.add(ListItem.FileItem(file))
        }
        items = grouped
        notifyDataSetChanged()
    }

    override fun getItemViewType(position: Int): Int = when (items[position]) {
        is ListItem.Header -> TYPE_HEADER
        is ListItem.FileItem -> TYPE_FILE
    }

    override fun getItemCount(): Int = items.size

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder {
        val inflater = LayoutInflater.from(parent.context)
        return when (viewType) {
            TYPE_HEADER -> HeaderViewHolder(inflater.inflate(R.layout.item_date_header, parent, false))
            else -> FileViewHolder(inflater.inflate(R.layout.item_file_row, parent, false))
        }
    }

    override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
        when (val item = items[position]) {
            is ListItem.Header -> (holder as HeaderViewHolder).bind(item.title, position == 0)
            is ListItem.FileItem -> (holder as FileViewHolder).bind(item.file)
        }
    }

    inner class HeaderViewHolder(view: View) : RecyclerView.ViewHolder(view) {
        fun bind(title: String, isFirst: Boolean) {
            val label = itemView.findViewById<TextView>(R.id.dateHeaderLabel)
            label.text = title
            // Match iOS: 40dp gap before each group, none before the first.
            val density = itemView.resources.displayMetrics.density
            val topPad = if (isFirst) 0 else (40 * density).toInt()
            label.setPadding(label.paddingLeft, topPad, label.paddingRight, label.paddingBottom)
        }
    }

    inner class FileViewHolder(view: View) : RecyclerView.ViewHolder(view) {
        fun bind(file: RecordingFile) {
            itemView.findViewById<TextView>(R.id.fileNameLabel).text = file.name
            itemView.findViewById<TextView>(R.id.fileMetaLabel).text = formatMeta(file)
            itemView.setOnClickListener { onFileTapped(file) }
        }

        private fun formatMeta(file: RecordingFile): String {
            val dateFormat = SimpleDateFormat("MMM d", Locale.getDefault())
            val timeFormat = SimpleDateFormat("HH:mm", Locale.getDefault())
            val date = Date(file.createdAt)
            val dur = formatDuration(file.duration)
            return "${dateFormat.format(date)}  \u00B7  ${timeFormat.format(date)}  \u00B7  $dur"
        }

        private fun formatDuration(seconds: Long): String {
            if (seconds <= 0) return "--"
            val total = seconds.toInt()
            return if (total >= 3600) {
                String.format("%dh %dm", total / 3600, (total % 3600) / 60)
            } else {
                String.format("%dm %ds", total / 60, total % 60)
            }
        }
    }
}
