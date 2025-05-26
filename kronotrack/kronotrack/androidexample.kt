package com.kronotiming.kronotrack

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.content.SharedPreferences
import android.os.Build
import android.os.Bundle
import android.widget.*
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import android.location.LocationManager
import android.provider.Settings
import android.app.AlertDialog
import android.content.BroadcastReceiver
import android.content.IntentFilter
import android.widget.AutoCompleteTextView
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.RequestBody
import okhttp3.Response
import org.json.JSONObject
import org.osmdroid.config.Configuration
import org.osmdroid.views.MapView
import org.osmdroid.util.GeoPoint
import org.osmdroid.views.overlay.Polyline
import org.osmdroid.views.overlay.mylocation.MyLocationNewOverlay
import org.osmdroid.views.overlay.mylocation.GpsMyLocationProvider
import org.osmdroid.tileprovider.tilesource.OnlineTileSourceBase
import org.osmdroid.tileprovider.tilesource.TileSourceFactory
import org.osmdroid.tileprovider.MapTileProviderBasic
import org.osmdroid.util.MapTileIndex
import android.view.Menu
import android.view.MenuItem
import android.net.Uri
import android.util.Log
import com.google.android.gms.common.api.ResolvableApiException
import com.google.android.gms.location.*
import org.osmdroid.views.overlay.Overlay
import org.osmdroid.views.Projection
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Point
import android.view.View
import androidx.drawerlayout.widget.DrawerLayout
import com.google.android.material.navigation.NavigationView
import androidx.appcompat.app.ActionBarDrawerToggle
import android.view.Gravity
import androidx.core.view.GravityCompat
import org.osmdroid.views.overlay.Marker
import org.osmdroid.views.overlay.infowindow.InfoWindow
import org.osmdroid.views.overlay.MapEventsOverlay
import org.osmdroid.events.MapEventsReceiver
import com.kronotiming.kronotrack.TrackData
import com.kronotiming.kronotrack.TrackMarker

class MainActivity : AppCompatActivity() {
    private lateinit var autocompleteCourse: AutoCompleteTextView
    private lateinit var editBib: EditText
    private lateinit var editBirthYear: EditText
    private lateinit var buttonStartStop: Button
    private lateinit var prefs: SharedPreferences
    private val client = OkHttpClient()
    private val courses = mutableListOf<String>()
    private lateinit var mapView: MapView
    private var myLocationOverlay: MyLocationNewOverlay? = null
    private lateinit var settingsClient: SettingsClient
    private lateinit var editCode: EditText // 6-digit code field
    private lateinit var participantNameTextView: TextView
    private lateinit var raceNameTextView: TextView
    private lateinit var participantInfoCard: View
    private lateinit var courseInputLayout: com.google.android.material.textfield.TextInputLayout
    private lateinit var viewModel: TrackingViewModel

    private val PERMISSION_REQUEST_FOREGROUND = 1
    private val PERMISSION_REQUEST_BACKGROUND = 2
    private val PERMISSION_REQUEST_NOTIFICATIONS = 1001
    private val REQUEST_CHECK_SETTINGS = 2002
    
    private val trackingStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == "com.kronotiming.kronotrack.TRACKING_STOPPED") {
                updateUIForStoppedTracking()
            }
        }
    }

    // Temporary storage for user input during permission flow
    private var pendingCourse: String? = null
    private var pendingBib: String? = null
    private var pendingBirthYear: String? = null
    private var pendingCode: String? = null

    // Add receiver to monitor location provider changes
    private val locationProviderChangedReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == LocationManager.PROVIDERS_CHANGED_ACTION) {
                //Log.i("LocationProviderChangedReceiver", "Location provider changed")
                val locationManager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
                val gpsEnabled = locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)
                if (!gpsEnabled && viewModel.isTracking.value == true) {
                    // Stop tracking and show dialog
                    stopTracking()
                    showTrackingStoppedDueToLocationDisabledDialog()
                }
            }
        }
    }

    // Receiver for service-initiated tracking stop due to location disabled
    private val trackingStoppedByLocationDisabledReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            updateUIForStoppedTracking()
            showTrackingStoppedDueToLocationDisabledDialog()
        }
    }

    private var locationService: LocationService? = null
    private var isServiceBound = false
    private val serviceConnection = object : android.content.ServiceConnection {
        override fun onServiceConnected(name: android.content.ComponentName?, service: android.os.IBinder?) {
            val binder = service as? LocationService.LocalBinder
            val tracking = binder?.isTracking() ?: false
            viewModel.isTracking.value = tracking
            if (tracking) {
                restoreState()
                updateUIForTracking()
            } else {
                restoreState()
                updateUIForStoppedTracking()
            }
        }
        override fun onServiceDisconnected(name: android.content.ComponentName?) {
            isServiceBound = false
        }
    }

    private fun updateUIForTracking() {
        courseInputLayout.isEnabled = false
        editBib.isEnabled = false
        editBirthYear.isEnabled = false
        editCode.isEnabled = false
        buttonStartStop.text = getString(R.string.stop_tracking)
        buttonStartStop.isEnabled = true
        myLocationOverlay?.enableMyLocation()
        updateRecenterButtonsState()
        participantInfoCard.visibility = View.VISIBLE
    }

    override fun onStart() {
        super.onStart()
        val intent = Intent(this, LocationService::class.java)
        bindService(intent, serviceConnection, Context.BIND_AUTO_CREATE)
        isServiceBound = true
    }

    override fun onStop() {
        super.onStop()
        if (isServiceBound) {
            unbindService(serviceConnection)
            isServiceBound = false
        }
    }

    private lateinit var drawerLayout: DrawerLayout
    private lateinit var navigationView: NavigationView
    private lateinit var toggle: ActionBarDrawerToggle

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Configuration.getInstance().load(applicationContext, getSharedPreferences("osmdroid", Context.MODE_PRIVATE))
        setContentView(R.layout.activity_main)
        autocompleteCourse = findViewById(R.id.autocomplete_course)
        courseInputLayout = findViewById(R.id.textInputLayout_course)
        editBib = findViewById(R.id.edit_bib)
        editBirthYear = findViewById(R.id.edit_birth_year)
        buttonStartStop = findViewById(R.id.button_start_stop)
        prefs = getSharedPreferences("krono_prefs", Context.MODE_PRIVATE)
        editCode = findViewById(R.id.edit_code)
        participantNameTextView = findViewById(R.id.text_participant_name)
        raceNameTextView = findViewById(R.id.text_race_name)
        participantInfoCard = findViewById(R.id.card_participant_info)
        participantInfoCard.visibility = View.GONE
        // Initialize the settings client for location settings
        settingsClient = LocationServices.getSettingsClient(this)
        loadCourses()
        // ...existing code for buttonStartStop, listeners, etc...
        mapView = findViewById(R.id.map_view)
        mapView.setMultiTouchControls(true)
        mapView.setBuiltInZoomControls(false)
        // ...existing code for mapView setup...
        viewModel = androidx.lifecycle.ViewModelProvider(this, androidx.lifecycle.ViewModelProvider.AndroidViewModelFactory.getInstance(application)).get(TrackingViewModel::class.java)
        // Now that mapView and all views are initialized, restore state
        restoreState()
        // Disable button initially
        buttonStartStop.isEnabled = false
        // ...existing code...
        // Disable button initially
        buttonStartStop.isEnabled = false

        // Helper to check fields and enable/disable button
        fun updateButtonState() {
            val bibNotEmpty = editBib.text.toString().isNotBlank()
            val courseNotEmpty = autocompleteCourse.text.toString().isNotBlank()
            val year = editBirthYear.text.toString()
            val yearValid = year.length == 4 && year.all { it.isDigit() }
            val codeValid = editCode.text.toString().length == 6
            buttonStartStop.isEnabled = bibNotEmpty && courseNotEmpty && yearValid && codeValid && viewModel.isTracking.value != true
        }

        // Listen for bib changes
        editBib.addTextChangedListener(object : android.text.TextWatcher {
            override fun afterTextChanged(s: android.text.Editable?) { updateButtonState() }
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
        })
        // Listen for course selection
        autocompleteCourse.setOnItemClickListener { _, _, _, _ -> updateButtonState() }
        // Also listen for manual text changes in course field
        autocompleteCourse.addTextChangedListener(object : android.text.TextWatcher {
            override fun afterTextChanged(s: android.text.Editable?) { updateButtonState() }
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
        })
        // Listen for birth year changes
        editBirthYear.addTextChangedListener(object : android.text.TextWatcher {
            override fun afterTextChanged(s: android.text.Editable?) { updateButtonState() }
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
        })

        // Listen for code changes
        editCode.addTextChangedListener(object : android.text.TextWatcher {
            override fun afterTextChanged(s: android.text.Editable?) { updateButtonState() }
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
        })

        // If the course list is empty, refetch when user tries to open the dropdown
        autocompleteCourse.setOnClickListener {
            if (courses.isEmpty()) {
                loadCourses()
            }
        }

        buttonStartStop.setOnClickListener {
            if (viewModel.isTracking.value != true) {
                startTracking()
            } else {
                confirmStopTracking()
            }
        }
        
        // Register broadcast receiver with the not exported flag
        val filter = IntentFilter("com.kronotiming.kronotrack.TRACKING_STOPPED")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(trackingStateReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(trackingStateReceiver, filter)
        }

        mapView = findViewById(R.id.map_view)
        mapView.setMultiTouchControls(true)
        mapView.setBuiltInZoomControls(false) // Disable built-in zoom controls
        // Set OpenTopoMap as tile source
        val openTopoMap = object : OnlineTileSourceBase(
            "OpenTopoMap",
            0, 18, 256, "",
            arrayOf("https://tile.opentopomap.org/")
        ) {
            override fun getTileURLString(pMapTileIndex: Long): String {
                val zoom = MapTileIndex.getZoom(pMapTileIndex)
                val x = MapTileIndex.getX(pMapTileIndex)
                val y = MapTileIndex.getY(pMapTileIndex)
                return baseUrl + "$zoom/$x/$y.png"
            }
        }
        mapView.setTileSource(openTopoMap)
        mapView.controller.setZoom(15.0)
        mapView.setMaxZoomLevel(19.0)
        mapView.setMinZoomLevel(5.0)
        myLocationOverlay = MyLocationNewOverlay(GpsMyLocationProvider(this), mapView)
        // Create a glowing purple dot Bitmap for the location marker, perfectly centered
        val size = 64
        val dotBitmap = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(dotBitmap)
        val cx = size / 2f
        val cy = size / 2f
        // Outer white glow, ensure it fits within the bitmap
        val outerRadius = (size - 2) / 2f // leave 1px margin
        val outerPaint = android.graphics.Paint().apply {
            isAntiAlias = true
            style = android.graphics.Paint.Style.FILL
            color = android.graphics.Color.WHITE
            alpha = 210 // semi-opaque for glow
        }
        canvas.drawCircle(cx, cy, outerRadius, outerPaint)
        // Inner fully opaque purple circle (same as track:rgb(174, 94, 255)), also centered
        val innerRadius = outerRadius * 0.6f // 60% of outer for good glow
        val innerPaint = android.graphics.Paint().apply {
            isAntiAlias = true
            style = android.graphics.Paint.Style.FILL
            color = android.graphics.Color.parseColor("#B266FF")
            alpha = 255 // fully opaque
        }
        canvas.drawCircle(cx, cy, innerRadius, innerPaint)
        val overlay = myLocationOverlay
        if (overlay != null) {
            overlay.setPersonIcon(dotBitmap)
            overlay.setPersonAnchor(0.5F, 0.5F)
            overlay.setDirectionIcon(dotBitmap)
            overlay.setDirectionAnchor(0.5F, 0.5F)


            mapView.overlays.add(overlay)
            overlay.enableMyLocation()
        }
       
        // New recenter buttons (bottom left)
        val buttonCenterLocation = findViewById<com.google.android.material.floatingactionbutton.FloatingActionButton>(R.id.button_center_location)
        val buttonCenterTrack = findViewById<com.google.android.material.floatingactionbutton.FloatingActionButton>(R.id.button_center_track)
        buttonCenterLocation.setOnClickListener {
            myLocationOverlay?.myLocation?.let {
                mapView.controller.animateTo(it)
            }
        }
        buttonCenterTrack.setOnClickListener {
            val points = viewModel.trackData.value?.points ?: emptyList<GeoPoint>()
            if (points.isNotEmpty()) {
                val paddedBbox = getPaddedBoundingBox(points)
                mapView.zoomToBoundingBox(paddedBbox, true)
            }
        }
        updateRecenterButtonsState()

        viewModel = androidx.lifecycle.ViewModelProvider(this, androidx.lifecycle.ViewModelProvider.AndroidViewModelFactory.getInstance(application)).get(TrackingViewModel::class.java)
        // Observe ViewModel state and update UI accordingly
        viewModel.course.observe(this) { if (autocompleteCourse.text.toString() != it) autocompleteCourse.setText(it, false) }
        viewModel.bib.observe(this) { if (editBib.text.toString() != it) editBib.setText(it) }
        viewModel.birthYear.observe(this) { if (editBirthYear.text.toString() != it) editBirthYear.setText(it) }
        viewModel.code.observe(this) { if (editCode.text.toString() != it) editCode.setText(it) }
        viewModel.buttonText.observe(this) { buttonStartStop.text = it }
        viewModel.buttonEnabled.observe(this) { buttonStartStop.isEnabled = it }
        viewModel.participantFirstName.observe(this) { updateParticipantInfo() }
        viewModel.participantLastName.observe(this) { updateParticipantInfo() }
        viewModel.eventName.observe(this) { updateParticipantInfo() }
        viewModel.participantInfoVisible.observe(this) { participantInfoCard.visibility = if (it) View.VISIBLE else View.GONE }
        viewModel.trackData.observe(this) { trackData: TrackData -> drawTrackOnMap(trackData) }

        // Listeners update ViewModel, not UI directly
        editBib.addTextChangedListener(object : android.text.TextWatcher {
            override fun afterTextChanged(s: android.text.Editable?) {
                viewModel.bib.value = s?.toString() ?: ""
                updateButtonStateFromViewModel()
            }
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
        })
        autocompleteCourse.setOnItemClickListener { _, _, _, _ ->
            viewModel.course.value = autocompleteCourse.text.toString()
            updateButtonStateFromViewModel()
        }
        autocompleteCourse.addTextChangedListener(object : android.text.TextWatcher {
            override fun afterTextChanged(s: android.text.Editable?) {
                viewModel.course.value = s?.toString() ?: ""
                updateButtonStateFromViewModel()
            }
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
        })
        editBirthYear.addTextChangedListener(object : android.text.TextWatcher {
            override fun afterTextChanged(s: android.text.Editable?) {
                viewModel.birthYear.value = s?.toString() ?: ""
                updateButtonStateFromViewModel()
            }
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
        })
        editCode.addTextChangedListener(object : android.text.TextWatcher {
            override fun afterTextChanged(s: android.text.Editable?) {
                viewModel.code.value = s?.toString() ?: ""
                updateButtonStateFromViewModel()
            }
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
        })

        val buttonMenu = findViewById<com.google.android.material.floatingactionbutton.FloatingActionButton>(R.id.button_menu)
        buttonMenu.setOnClickListener {
            if (drawerLayout.isDrawerOpen(GravityCompat.START)) {
                drawerLayout.closeDrawer(GravityCompat.START)
            } else {
                drawerLayout.openDrawer(GravityCompat.START)
            }
        }

        // Initialize DrawerLayout and NavigationView
        drawerLayout = findViewById(R.id.drawer_layout)
        navigationView = findViewById(R.id.navigation_view)

        // Handle navigation item clicks
        navigationView.setNavigationItemSelectedListener { menuItem ->
            when (menuItem.itemId) {
                R.id.nav_privacy_policy -> {
                    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(getString(R.string.privacy_policy_url)))
                    startActivity(intent)
                }
                R.id.nav_results -> {
                    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(getString(R.string.results_url)))
                    startActivity(intent)
                }
            }
            drawerLayout.closeDrawer(GravityCompat.START)
            true
        }

        // Add overlay to close marker info windows when tapping elsewhere on the map
        val mapEventsOverlay = MapEventsOverlay(object : MapEventsReceiver {
            override fun singleTapConfirmedHelper(p: GeoPoint?): Boolean {
                // Close all open info windows
                org.osmdroid.views.overlay.infowindow.InfoWindow.closeAllInfoWindowsOn(mapView)
                return false // return false to allow other tap events
            }
            override fun longPressHelper(p: GeoPoint?): Boolean {
                return false
            }
        })
        mapView.overlays.add(0, mapEventsOverlay) // Add as the first overlay so it doesn't block marker taps
    }

    // Override onOptionsItemSelected
    override fun onOptionsItemSelected(item: MenuItem): Boolean {
        if (toggle.onOptionsItemSelected(item)) {
            return true
        }
        return super.onOptionsItemSelected(item)
    }

    // Helper to update button state from ViewModel fields
    private fun updateButtonStateFromViewModel() {
        val bibNotEmpty = viewModel.bib.value?.isNotBlank() == true
        val courseNotEmpty = viewModel.course.value?.isNotBlank() == true
        val year = viewModel.birthYear.value ?: ""
        val yearValid = year.length == 4 && year.all { it.isDigit() }
        val codeValid = viewModel.code.value?.length == 6
        val tracking = viewModel.isTracking.value == true
        // Always enable the button if tracking is ongoing, otherwise use the field checks
        viewModel.buttonEnabled.value = if (tracking) true else (bibNotEmpty && courseNotEmpty && yearValid && codeValid)
    }

    override fun onResume() {
        super.onResume()
        mapView.onResume()
        myLocationOverlay?.enableMyLocation()
        // Register location provider changed receiver
        val filter = IntentFilter(LocationManager.PROVIDERS_CHANGED_ACTION)
        registerReceiver(locationProviderChangedReceiver, filter)
        // Check location services state on resume
        val locationManager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val gpsEnabled = locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)
        if (viewModel.isTracking.value == true && !gpsEnabled) {
            updateUIForStoppedTracking()
            showTrackingStoppedDueToLocationDisabledDialog()
        }
        // Use .points from TrackData for centering
        val trackPoints = viewModel.trackData.value?.points ?: emptyList<org.osmdroid.util.GeoPoint>()
        if (trackPoints.isNotEmpty()) {
            mapView.post {
                val paddedBbox = getPaddedBoundingBox(trackPoints)
                mapView.zoomToBoundingBox(paddedBbox, true)
            }
        }
        updateRecenterButtonsState()
    }
    override fun onPause() {
        super.onPause()
        mapView.onPause()
        myLocationOverlay?.disableMyLocation()
        // Unregister location provider changed receiver
        try {
            unregisterReceiver(locationProviderChangedReceiver)
        } catch (_: Exception) {}
        // Unregister service-initiated tracking stop receiver
        try {
            unregisterReceiver(trackingStoppedByLocationDisabledReceiver)
        } catch (_: Exception) {}
    }
    override fun onDestroy() {
        super.onDestroy()
        mapView.onDetach()
        try {
            unregisterReceiver(trackingStateReceiver)
        } catch (e: Exception) {
            // Receiver might not be registered
        }
        try {
            unregisterReceiver(trackingStoppedByLocationDisabledReceiver)
        } catch (_: Exception) {}
    }
    override fun onLowMemory() {
        super.onLowMemory()
    }

    private fun loadCourses() {
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val request = Request.Builder().url("https://track.kronotiming.fr/events").build()
                val response = client.newCall(request).execute()
                val body = response.body?.string() ?: throw Exception("Empty response body")
                // Parse as JSON and extract "events" array
                val obj = org.json.JSONObject(body)
                if (!obj.has("events")) throw Exception("Missing 'events' field")
                val arr = obj.getJSONArray("events")
                if (arr.length() == 0) throw Exception("Empty 'events' array")
                val eventList = mutableListOf<String>()
                for (i in 0 until arr.length()) {
                    val event = arr.optString(i, null)
                    if (event == null) throw Exception("Non-string event entry")
                    eventList.add(event)
                }
                withContext(Dispatchers.Main) {
                    courses.clear()
                    courses.addAll(eventList)
                    val adapter = ArrayAdapter(this@MainActivity, android.R.layout.simple_dropdown_item_1line, courses)
                    autocompleteCourse.setAdapter(adapter)
                    // Restore saved course selection if present
                    val savedCourse = prefs.getString("course", "") ?: ""
                    if (savedCourse.isNotBlank()) {
                        val idx = courses.indexOf(savedCourse)
                        if (idx >= 0) autocompleteCourse.setText(courses[idx], false)
                    }
                }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    Toast.makeText(this@MainActivity, getString(R.string.error_loading_courses), Toast.LENGTH_SHORT).show()
                }
            }
        }
    }

    private fun hasAllLocationPermissions(): Boolean {
        val fine = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED
        val coarse = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED
        val background = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_BACKGROUND_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED
        } else true
        val foregroundServiceLocation = if (Build.VERSION.SDK_INT >= 34) {
            ContextCompat.checkSelfPermission(this, Manifest.permission.FOREGROUND_SERVICE_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED
        } else true
        return fine && coarse && background && foregroundServiceLocation
    }

    private fun requestForegroundLocationPermissions() {
        val permissions = arrayOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION
        )
        ActivityCompat.requestPermissions(this, permissions, PERMISSION_REQUEST_FOREGROUND)
    }

    private fun requestBackgroundLocationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val permissions = arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
            ActivityCompat.requestPermissions(this, permissions, PERMISSION_REQUEST_BACKGROUND)
        } else {
            val birthYear = editBirthYear.text.toString()
            actuallyStartTracking(birthYear)
        }
    }

    private fun showBackgroundLocationRationale() {
        val dialog = AlertDialog.Builder(this)
            .setTitle(getString(R.string.background_location_permission_title))
            .setMessage(getString(R.string.background_location_permission_message))
            .setPositiveButton(getString(R.string.continue_action)) { _, _ ->
                requestBackgroundLocationPermission()
            }
            .setNegativeButton(getString(R.string.cancel)) { _, _ ->
                Toast.makeText(this, getString(R.string.background_location_required), Toast.LENGTH_SHORT).show()
                stopTracking()
            }
            .show()
        // Set dialog button colors
        val color = ContextCompat.getColor(this, R.color.dialog_button_text)
        dialog.getButton(AlertDialog.BUTTON_POSITIVE)?.setTextColor(color)
        dialog.getButton(AlertDialog.BUTTON_NEGATIVE)?.setTextColor(color)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        when (requestCode) {
            PERMISSION_REQUEST_NOTIFICATIONS -> {
                if (grantResults.isNotEmpty() && grantResults[0] != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    // Permission denied, show dialog to guide user to settings
                    val dialog = AlertDialog.Builder(this)
                        .setTitle(getString(R.string.notifications_required_title))
                        .setMessage(getString(R.string.notifications_required_message))
                        .setPositiveButton(getString(R.string.open_settings)) { _, _ ->
                            val intent = Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                                putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, packageName)
                            }
                            startActivity(intent)
                        }
                        .setNegativeButton(getString(R.string.cancel), null)
                        .show()
                    // Set dialog button colors
                    val color = ContextCompat.getColor(this, R.color.dialog_button_text)
                    dialog.getButton(AlertDialog.BUTTON_POSITIVE)?.setTextColor(color)
                    dialog.getButton(AlertDialog.BUTTON_NEGATIVE)?.setTextColor(color)
                    
                    // Clean up pending tracking state when notification permission is denied
                    viewModel.isTrackingPending.value = false
                    prefs.edit().remove("is_tracking_pending").apply()
                    // Reset any stored pending values
                    pendingCourse = null
                    pendingBib = null
                    pendingBirthYear = null
                    pendingCode = null
                    updateUIForStoppedTracking() // This will re-enable the button and input fields
                } else {
                    // Permission granted, resume startTracking with pending values
                    proceedToStartTracking()
                }
            }
            PERMISSION_REQUEST_FOREGROUND -> {
                val granted = grantResults.isNotEmpty() && grantResults.all { it == android.content.pm.PackageManager.PERMISSION_GRANTED }
                if (granted) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        showBackgroundLocationRationale()
                    } else {
                        if (!isGpsEnabled()) {
                            val (course, bib, birthYear, code) = getTrackingInput()
                            pendingCourse = course
                            pendingBib = bib
                            pendingBirthYear = birthYear
                            pendingCode = code
                            promptEnableGps()
                            return
                        }
                        proceedToStartTracking()
                    }
                } else {
                    Toast.makeText(this, getString(R.string.location_permissions_required), Toast.LENGTH_SHORT).show()
                    stopTracking()
                }
            }
            PERMISSION_REQUEST_BACKGROUND -> {
                val granted = grantResults.isNotEmpty() && grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED
                if (granted) {
                    if (!isGpsEnabled()) {
                        val (course, bib, birthYear, code) = getTrackingInput()
                        pendingCourse = course
                        pendingBib = bib
                        pendingBirthYear = birthYear
                        pendingCode = code
                        promptEnableGps()
                        return
                    }
                    proceedToStartTracking()
                } else {
                    Toast.makeText(this, getString(R.string.background_location_required), Toast.LENGTH_SHORT).show()
                    stopTracking()
                }
            }
        }
    }

    private fun isGpsEnabled(): Boolean {
        val locationManager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        return locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)
    }

    private fun promptEnableGps() {
        // Create location request with high accuracy settings
        val locationRequest = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 10000)
            .setMinUpdateIntervalMillis(5000)
            .build()
            
        // Build location settings request
        val builder = LocationSettingsRequest.Builder()
            .addLocationRequest(locationRequest)
            .setAlwaysShow(true) // This forces the dialog to show every time

        // Show location settings dialog using the settings client
        val task = settingsClient.checkLocationSettings(builder.build())
        
        // Add listener to handle success/failure
        task.addOnSuccessListener { 
            // Location settings are already enabled with high accuracy
            proceedToStartTracking()
        }
        
        task.addOnFailureListener { exception ->
            if (exception is ResolvableApiException) {
                // Location settings are not satisfied, but can be resolved by showing a system dialog
                try {
                    // Show the dialog by calling startResolutionForResult
                    exception.startResolutionForResult(this@MainActivity, REQUEST_CHECK_SETTINGS)
                } catch (sendEx: IntentSender.SendIntentException) {
                    // Ignore the error
                    // Log.e("LocationSettings", "Error showing location settings resolution dialog", sendEx)
                }
            } else {
                // Location settings issues can't be resolved automatically, fall back to manual settings
                val dialog = AlertDialog.Builder(this)
                    .setTitle(getString(R.string.enable_location_title))
                    .setMessage(getString(R.string.enable_location_message))
                    .setPositiveButton(getString(R.string.enable)) { _, _ ->
                        startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS))
                    }
                    .setNegativeButton(getString(R.string.cancel), null)
                    .show()
                // Set dialog button colors
                val color = ContextCompat.getColor(this, R.color.dialog_button_text)
                dialog.getButton(AlertDialog.BUTTON_POSITIVE)?.setTextColor(color)
                dialog.getButton(AlertDialog.BUTTON_NEGATIVE)?.setTextColor(color)
            }
        }
    }

    private fun startTracking() {
        // Invalidate previous participant info and track points immediately
        prefs.edit()
            .remove("participant_first_name")
            .remove("participant_last_name")
            .remove("event_name")
            .remove("track_points")
            .apply()
        val course = viewModel.course.value ?: ""
        val bib = viewModel.bib.value ?: ""
        val birthYear = viewModel.birthYear.value ?: ""
        val code = viewModel.code.value ?: ""
        if (course.isBlank() || bib.isBlank() || birthYear.isBlank() || code.length != 6) {
            Toast.makeText(this, getString(R.string.select_course_bib_birthyear), Toast.LENGTH_SHORT).show()
            return
        }
        val year = birthYear.toIntOrNull()
        if (year == null || birthYear.length != 4) {
            Toast.makeText(this, getString(R.string.invalid_birth_year), Toast.LENGTH_SHORT).show()
            return
        }
        if (code.length != 6) {
            Toast.makeText(this, getString(R.string.invalid_code), Toast.LENGTH_SHORT).show()
            return
        }
        // Save user input and pending state to ViewModel and SharedPreferences
        viewModel.isTrackingPending.value = true
        viewModel.isTracking.value = false
        viewModel.buttonEnabled.value = false
        // Do NOT set buttonText to stop_tracking here
        viewModel.participantInfoVisible.value = false
        prefs.edit()
            .putString("course", course)
            .putString("bib", bib)
            .putString("birth_year", birthYear)
            .putString("code", code)
            .putBoolean("is_tracking_pending", true)
            .apply()
        // 1. Check notification permission (if needed)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                pendingCourse = course
                pendingBib = bib
                pendingBirthYear = birthYear
                pendingCode = code
                ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST_NOTIFICATIONS)
                return
            }
        }
        // 2. Check location permissions
        if (!hasAllLocationPermissions()) {
            pendingCourse = course
            pendingBib = bib
            pendingBirthYear = birthYear
            pendingCode = code
            requestForegroundLocationPermissions()
            return
        }
        // 3. Only after permissions are granted, check if GPS is enabled
        if (!isGpsEnabled()) {
            // Save pending values to resume after enabling GPS
            pendingCourse = course
            pendingBib = bib
            pendingBirthYear = birthYear
            pendingCode = code
            promptEnableGps()
            return
        }
        // 4. All good, proceed
        proceedToStartTracking()
    }

    private fun fetchAndDisplayTrack(course: String, bib: String, birthYear: String, code: String) {
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val json = JSONObject().apply {
                    put("main_event", course)
                    put("bib", bib.toInt())
                    put("birth_year", birthYear.toInt())
                    put("code", code)
                }
                val body: RequestBody = json.toString().toRequestBody("application/json".toMediaTypeOrNull())
                val request = okhttp3.Request.Builder()
                    .url("https://live.kronotiming.fr/track")
                    .post(body)
                    .build()
                val response: Response = client.newCall(request).execute()
                if (!response.isSuccessful) {
                    withContext(Dispatchers.Main) {
                        when (response.code) {
                            404 -> {
                                val dialog = AlertDialog.Builder(this@MainActivity)
                                    .setMessage(getString(R.string.invalid_bib_or_birth_year))
                                    .setPositiveButton(getString(R.string.close), null)
                                    .show()
                                val color = ContextCompat.getColor(this@MainActivity, R.color.dialog_button_text)
                                dialog.getButton(AlertDialog.BUTTON_POSITIVE)?.setTextColor(color)
                            }
                            403 -> {
                                val dialog = AlertDialog.Builder(this@MainActivity)
                                    .setMessage(getString(R.string.invalid_code_course))
                                    .setPositiveButton(getString(R.string.close), null)
                                    .show()
                                val color = ContextCompat.getColor(this@MainActivity, R.color.dialog_button_text)
                                dialog.getButton(AlertDialog.BUTTON_POSITIVE)?.setTextColor(color)
                            }
                            else -> {
                                Toast.makeText(this@MainActivity, getString(R.string.error_loading_track), Toast.LENGTH_SHORT).show()
                            }
                        }
                        // Stay in original state, do not start tracking
                        updateUIForStoppedTracking()
                        buttonStartStop.isEnabled = true // Re-enable button on error
                    }
                    // On error, clear pending state
                    prefs.edit().remove("is_tracking_pending").apply()
                    return@launch
                }
                val responseBody = response.body?.string() ?: return@launch
                val trackData = parseTrackCoordinates(responseBody)
                // Extract runner info from JSON
                val obj = org.json.JSONObject(responseBody)
                val firstName = obj.optString("firstName", "")
                val lastName = obj.optString("lastName", "")
                val eventName = obj.optString("eventName", "")
                // Save participant info and full track data (points + markers) to SharedPreferences
                prefs.edit()
                    .putString("participant_first_name", firstName)
                    .putString("participant_last_name", lastName)
                    .putString("event_name", eventName)
                    .putString("track_data", responseBody) // Store the full JSON (track + markers)
                    .putBoolean("is_tracking", true)
                    .remove("is_tracking_pending")
                    .apply()
                withContext(Dispatchers.Main) {
                    viewModel.participantFirstName.value = firstName
                    viewModel.participantLastName.value = lastName
                    viewModel.eventName.value = eventName
                    viewModel.trackData.value = trackData
                    viewModel.isTracking.value = true
                    viewModel.isTrackingPending.value = false
                    viewModel.buttonEnabled.value = true
                    viewModel.buttonText.value = getString(R.string.stop_tracking)
                    viewModel.participantInfoVisible.value = true
                    actuallyStartTracking(birthYear)
                    buttonStartStop.isEnabled = true
                }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    viewModel.isTrackingPending.value = false
                    viewModel.isTracking.value = false
                    viewModel.buttonEnabled.value = true
                    viewModel.buttonText.value = getString(R.string.start_tracking)
                    viewModel.participantInfoVisible.value = false
                    Toast.makeText(this@MainActivity, getString(R.string.error_loading_track), Toast.LENGTH_SHORT).show()
                    updateUIForStoppedTracking()
                    buttonStartStop.isEnabled = true
                }
                prefs.edit().remove("is_tracking_pending").apply()
            }
        }
    }

    // Helper to map marker type to icon and label
    private fun getMarkerIconAndText(type: String): Pair<Int, String>? {
        return when (type) {
            "food" -> Pair(R.drawable.dining_48px, getString(R.string.marker_food))
            "water" -> Pair(R.drawable.water_drop_48px, getString(R.string.marker_water))
            "signal" -> Pair(R.drawable.emoji_people_48px, getString(R.string.marker_signal))
            "start" -> Pair(R.drawable.flag_2_48px, getString(R.string.start_point))
            else -> null
        }
    }

    // Helper to add a marker to the map
    private fun addTrackMarkerToMap(marker: TrackMarker, mapView: MapView) {
        val geoPoint = GeoPoint(marker.lat, marker.lon)
        val iconAndLabel = getMarkerIconAndText(marker.type)
        if (iconAndLabel == null) return // Ignore unknown marker types
        val (iconRes, label) = iconAndLabel
        val m = Marker(mapView)
        m.position = geoPoint
        val drawable = ContextCompat.getDrawable(this, iconRes)
        // Optionally tint icons by type if desired
        when (marker.type) {
            "food" -> drawable?.setColorFilter(android.graphics.Color.parseColor("#FF9800"), android.graphics.PorterDuff.Mode.SRC_IN) // Orange
            "water" -> drawable?.setColorFilter(android.graphics.Color.parseColor("#2196F3"), android.graphics.PorterDuff.Mode.SRC_IN) // Blue
            "signal" -> drawable?.setColorFilter(android.graphics.Color.parseColor("#E53935"), android.graphics.PorterDuff.Mode.SRC_IN) // Red
            "start" -> drawable?.setColorFilter(android.graphics.Color.parseColor("#2ECC40"), android.graphics.PorterDuff.Mode.SRC_IN) // Green
            else -> drawable?.clearColorFilter()
        }
        // Compose icon on black circle background
        if (drawable != null) {
            val iconSize = 72 // px, adjust as needed
            val circleRadius = iconSize / 2f
            val bitmap = android.graphics.Bitmap.createBitmap(iconSize, iconSize, android.graphics.Bitmap.Config.ARGB_8888)
            val canvas = android.graphics.Canvas(bitmap)
            // Draw black circle
            val paint = android.graphics.Paint().apply {
                isAntiAlias = true
                style = android.graphics.Paint.Style.FILL
                color = android.graphics.Color.BLACK
            }
            canvas.drawCircle(circleRadius, circleRadius, circleRadius, paint)
            // Draw the icon centered
            val iconInset = iconSize * 0.18f // leave some padding
            drawable.setBounds(iconInset.toInt(), iconInset.toInt(), (iconSize - iconInset).toInt(), (iconSize - iconInset).toInt())
            drawable.draw(canvas)
            m.icon = android.graphics.drawable.BitmapDrawable(resources, bitmap)
        } else {
            m.icon = drawable
        }
        
        m.title = label
        m.setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_BOTTOM)
        m.infoWindow = CustomMarkerInfoWindow(mapView)
        mapView.overlays.add(m)
    }

    // Update: parseTrackCoordinates now returns both points and markers
    private fun parseTrackCoordinates(json: String): TrackData {
        val points = mutableListOf<GeoPoint>()
        val markers = mutableListOf<TrackMarker>()
        val obj = org.json.JSONObject(json)
        if (obj.has("track")) {
            val arr = obj.getJSONArray("track")
            for (i in 0 until arr.length()) {
                val point = arr.getJSONArray(i)
                val lat = point.getDouble(0)
                val lng = point.getDouble(1)
                points.add(GeoPoint(lat, lng))
            }
        }
        if (obj.has("markers")) {
            val marr = obj.getJSONArray("markers")
            for (i in 0 until marr.length()) {
                val mobj = marr.getJSONObject(i)
                val lat = mobj.getDouble("lat")
                val lon = mobj.getDouble("lon")
                val type = mobj.optString("type", "other")
                markers.add(TrackMarker(lat, lon, type))
            }
        }
        return TrackData(points, markers)
    }

     private fun catmullRomSpline(points: List<GeoPoint>, segments: Int = 10): List<GeoPoint> {
        if (points.size < 2) return points
        val result = mutableListOf<GeoPoint>()
        for (i in 0 until points.size - 1) {
            val p0 = if (i == 0) points[i] else points[i - 1]
            val p1 = points[i]
            val p2 = points[i + 1]
            val p3 = if (i + 2 < points.size) points[i + 2] else points[i + 1]
            for (j in 0..segments) {
                val t = j / segments.toDouble()
                val t2 = t * t
                val t3 = t2 * t
                val lat = 0.5 * (
                    (2 * p1.latitude) +
                    (-p0.latitude + p2.latitude) * t +
                    (2 * p0.latitude - 5 * p1.latitude + 4 * p2.latitude - p3.latitude) * t2 +
                    (-p0.latitude + 3 * p1.latitude - 3 * p2.latitude + p3.latitude) * t3
                )
                val lon = 0.5 * (
                    (2 * p1.longitude) +
                    (-p0.longitude + p2.longitude) * t +
                    (2 * p0.longitude - 5 * p1.longitude + 4 * p2.longitude - p3.longitude) * t2 +
                    (-p0.longitude + 3 * p1.longitude - 3 * p2.longitude + p3.longitude) * t3
                )
                result.add(GeoPoint(lat, lon))
            }
        }
        return result
    }

    // Custom overlay for white glow polyline with rounded joins
    class GlowPolylineOverlay(private val points: List<GeoPoint>) : Overlay() {
        private val paint = Paint().apply {
            color = 0xAAFFFFFF.toInt() // semi-transparent white
            style = Paint.Style.STROKE
            strokeWidth = 22f
            isAntiAlias = true
            strokeJoin = Paint.Join.ROUND
            strokeCap = Paint.Cap.ROUND
        }
        override fun draw(canvas: android.graphics.Canvas, mapView: MapView, shadow: Boolean) {
            if (points.size < 2) return
            val proj: Projection = mapView.projection
            val path = Path()
            val pt = Point()
            proj.toPixels(points[0], pt)
            path.moveTo(pt.x.toFloat(), pt.y.toFloat())
            for (i in 1 until points.size) {
                proj.toPixels(points[i], pt)
                path.lineTo(pt.x.toFloat(), pt.y.toFloat())
            }
            canvas.drawPath(path, paint)
        }
    }

    // Store the current track points and markers for centering
    private var currentTrackPoints: List<GeoPoint> = emptyList()
    private var currentTrackMarkers: List<TrackMarker> = emptyList()

    // Helper to update recenter buttons state
    private fun updateRecenterButtonsState() {
        val buttonCenterTrack = findViewById<com.google.android.material.floatingactionbutton.FloatingActionButton>(R.id.button_center_track)
        val buttonCenterLocation = findViewById<com.google.android.material.floatingactionbutton.FloatingActionButton>(R.id.button_center_location)
        val trackEnabled = currentTrackPoints.isNotEmpty() // Enable if track is loaded
        buttonCenterTrack.isEnabled = trackEnabled
        buttonCenterTrack.alpha = if (trackEnabled) 1.0f else 0.6f
        val tracking = viewModel.isTracking.value == true
        buttonCenterLocation.isEnabled = tracking
        buttonCenterLocation.alpha = if (tracking) 1.0f else 0.6f
    }

    // Compute a padded bounding box for a list of points
    private fun getPaddedBoundingBox(points: List<GeoPoint>): org.osmdroid.util.BoundingBox {
        val bbox = org.osmdroid.util.BoundingBox.fromGeoPointsSafe(points)
        val latSpan = bbox.latNorth - bbox.latSouth
        val lonSpan = bbox.lonEast - bbox.lonWest
        val verticalPaddingFactor = 0.5 // 50% extra space above
        val horizontalPaddingFactor = 0.15 // 15% padding left/right
        val paddedLatNorth = bbox.latNorth + latSpan * verticalPaddingFactor
        val paddedLatSouth = bbox.latSouth
        val paddedLonWest = bbox.lonWest - lonSpan * horizontalPaddingFactor
        val paddedLonEast = bbox.lonEast + lonSpan * horizontalPaddingFactor
        return org.osmdroid.util.BoundingBox(
            paddedLatNorth,
            paddedLonEast,
            paddedLatSouth,
            paddedLonWest
        )
    }

    private fun drawTrackOnMap(trackData: TrackData) {
        val points = trackData.points
        val markers = trackData.markers
        // Remove all existing track-related overlays and markers
        mapView.overlays.removeAll { it is Polyline || it is GlowPolylineOverlay || it is Marker }
        myLocationOverlay?.let { mapView.overlays.remove(it) }
        val hadTrack = currentTrackPoints.isNotEmpty()
        currentTrackPoints = points // Save for centering
        currentTrackMarkers = markers
        updateRecenterButtonsState()
        if (points.isNotEmpty()) {
            // Draw white glow with custom overlay (no smoothing, just original points)
            val glowOverlay = GlowPolylineOverlay(points)
            mapView.overlays.add(glowOverlay)
            // Main bright blue polyline (smoothed)
            val smoothPoints = catmullRomSpline(points, segments = 8)
            val mainPolyline = Polyline()
            mainPolyline.setPoints(smoothPoints)
            mainPolyline.color = 0xFF33B5FF.toInt() // bright blue (ARGB)
            mainPolyline.width = 9f
            mapView.overlays.add(mainPolyline)
            myLocationOverlay?.let { mapView.overlays.add(it) }
            // Add all other markers except start
            for (marker in markers) {
                if (marker.type != "start") {
                    addTrackMarkerToMap(marker, mapView)
                }
            }
            // Add flag marker at the first point of the track (type = "start") last, so it's on top
            if (points.isNotEmpty()) {
                val start = TrackMarker(points.first().latitude, points.first().longitude, "start")
                addTrackMarkerToMap(start, mapView)
            }
            // Center and zoom to padded bounding box
            mapView.post {
                val paddedBbox = getPaddedBoundingBox(points)
                mapView.zoomToBoundingBox(paddedBbox, true)
                mapView.invalidate()
            }
        } else if (hadTrack) {
            // Only recenter to Grenoble if a track was just cleared
            mapView.post {
                val grenoble = GeoPoint(45.1885, 5.7245)
                mapView.controller.setCenter(grenoble)
                mapView.invalidate()
            }
        } else {
            mapView.invalidate()
        }
    }

    private fun clearTrack(resetCenter: Boolean = true) {
        // Remove all polylines and glow overlays from map
        mapView.overlays.removeAll { it is Polyline || it is GlowPolylineOverlay || it is Marker }
        currentTrackPoints = emptyList()
        updateRecenterButtonsState()
        if (resetCenter) {
            // Center back to default location
            val grenoble = GeoPoint(45.1885, 5.7245)
            mapView.controller.setCenter(grenoble)
        }
        mapView.invalidate()
    }

    private fun confirmStopTracking() {
        val dialog = AlertDialog.Builder(this)
            .setTitle(getString(R.string.stop_tracking_title))
            .setMessage(getString(R.string.stop_tracking_message))
            .setPositiveButton(getString(R.string.yes)) { _, _ ->
                stopTracking()
            }
            .setNegativeButton(getString(R.string.no), null)
            .show()
        // Set dialog button colors
        val color = ContextCompat.getColor(this, R.color.dialog_button_text)
        dialog.getButton(AlertDialog.BUTTON_POSITIVE)?.setTextColor(color)
        dialog.getButton(AlertDialog.BUTTON_NEGATIVE)?.setTextColor(color)
    }

    private fun actuallyStartTracking(birthYear: String) {
        val course = viewModel.course.value ?: ""
        val bib = viewModel.bib.value ?: ""
        val code = viewModel.code.value ?: ""
        prefs.edit()
            .putBoolean("is_tracking", true)
            .putString("course", course)
            .putString("bib", bib)
            .putString("birth_year", birthYear)
            .putString("code", code)
            .apply()
        viewModel.isTracking.value = true
        viewModel.isTrackingPending.value = false
        viewModel.buttonText.value = getString(R.string.stop_tracking)
        viewModel.buttonEnabled.value = true
        viewModel.participantInfoVisible.value = true
        autocompleteCourse.isEnabled = false
        editBib.isEnabled = false
        editBirthYear.isEnabled = false
        editCode.isEnabled = false
        myLocationOverlay?.enableMyLocation()
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        notificationManager.cancelAll()
        val intent = Intent(this, LocationService::class.java)
        intent.putExtra("bib", bib)
        intent.putExtra("main_event", course)
        intent.putExtra("birth_year", birthYear)
        intent.putExtra("code", code)
        ContextCompat.startForegroundService(this, intent)
        updateRecenterButtonsState()
    }

    private fun stopTracking() {
        // Set tracking state to false and clear participant info, but keep trackPoints
        viewModel.isTracking.value = false
        viewModel.isTrackingPending.value = false
        viewModel.participantInfoVisible.value = false
        viewModel.participantFirstName.value = ""
        viewModel.participantLastName.value = ""
        viewModel.eventName.value = ""
        prefs.edit()
            .remove("is_tracking")
            .remove("participant_first_name")
            .remove("participant_last_name")
            .remove("event_name")
            .apply()
        val intent = Intent(this, LocationService::class.java)
        stopService(intent)
        if (isServiceBound) {
            unbindService(serviceConnection)
            isServiceBound = false
        }
        // Ensure UI and ViewModel state are fully reset
        updateUIForStoppedTracking()
    }

    private fun updateUIForStoppedTracking() {
        autocompleteCourse.isEnabled = true
        editBib.isEnabled = true
        editBirthYear.isEnabled = true
        editCode.isEnabled = true
        viewModel.isTracking.value = false
        viewModel.isTrackingPending.value = false
        viewModel.buttonText.value = getString(R.string.start_tracking)
        updateButtonStateFromViewModel()
        viewModel.participantInfoVisible.value = false
        viewModel.participantFirstName.value = ""
        viewModel.participantLastName.value = ""
        viewModel.eventName.value = ""
        // Do NOT clear viewModel.trackPoints here
        myLocationOverlay?.disableMyLocation()
        // Do NOT call clearTrack(), so the track remains visible
        updateRecenterButtonsState()
    }

    private fun restoreState() {
        val bib = prefs.getString("bib", "") ?: ""
        val course = prefs.getString("course", "") ?: ""
        val birthYear = prefs.getString("birth_year", "") ?: ""
        val code = prefs.getString("code", "") ?: ""
        val isTracking = prefs.getBoolean("is_tracking", false)
        val isTrackingPending = prefs.getBoolean("is_tracking_pending", false)
        val firstName = prefs.getString("participant_first_name", "") ?: ""
        val lastName = prefs.getString("participant_last_name", "") ?: ""
        val eventName = prefs.getString("event_name", "") ?: ""
        val trackDataJson = prefs.getString("track_data", null)
        viewModel.course.value = course
        viewModel.bib.value = bib
        viewModel.birthYear.value = birthYear
        viewModel.code.value = code
        viewModel.isTracking.value = isTracking
        viewModel.isTrackingPending.value = isTrackingPending
        viewModel.participantFirstName.value = firstName
        viewModel.participantLastName.value = lastName
        viewModel.eventName.value = eventName
        if (!trackDataJson.isNullOrBlank()) {
            try {
                val trackData = parseTrackCoordinates(trackDataJson)
                viewModel.trackData.value = trackData
                if (trackData.points.isNotEmpty()) {
                    mapView.post {
                        val paddedBbox = getPaddedBoundingBox(trackData.points)
                        mapView.zoomToBoundingBox(paddedBbox, true)
                    }
                }
            } catch (_: Exception) {
                viewModel.trackData.value = TrackData(emptyList(), emptyList())
                mapView.post {
                    val grenoble = GeoPoint(45.1885, 5.7245)
                    mapView.controller.setCenter(grenoble)
                }
            }
        } else {
            viewModel.trackData.value = TrackData(emptyList(), emptyList())
            mapView.post {
                val grenoble = GeoPoint(45.1885, 5.7245)
                mapView.controller.setCenter(grenoble)
            }
        }
        if (isTracking) {
            viewModel.buttonText.value = getString(R.string.stop_tracking)
            viewModel.buttonEnabled.value = true
            viewModel.participantInfoVisible.value = true
        } else if (isTrackingPending) {
            viewModel.buttonText.value = getString(R.string.stop_tracking)
            viewModel.buttonEnabled.value = false
            viewModel.participantInfoVisible.value = false
        } else {
            viewModel.buttonText.value = getString(R.string.start_tracking)
            updateButtonStateFromViewModel()
            viewModel.participantInfoVisible.value = false
        }
    }

    private fun updateParticipantInfo() {
        val first = viewModel.participantFirstName.value ?: ""
        val last = viewModel.participantLastName.value ?: ""
        val event = viewModel.eventName.value ?: ""
        participantNameTextView.text = (first + " " + last).trim()
        raceNameTextView.text = event
    }

    // Show dialog when tracking is stopped due to location services being disabled
    private fun showTrackingStoppedDueToLocationDisabledDialog() {
        val dialog = AlertDialog.Builder(this)
            .setTitle(getString(R.string.tracking_stopped_title))
            .setMessage(getString(R.string.tracking_stopped_location_disabled))
            .setPositiveButton(android.R.string.ok, null)
            .show()
        val color = ContextCompat.getColor(this, R.color.dialog_button_text)
        dialog.getButton(AlertDialog.BUTTON_POSITIVE)?.setTextColor(color)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        
        // Handle the result of the location settings dialog
        if (requestCode == REQUEST_CHECK_SETTINGS) {
            when (resultCode) {
                RESULT_OK -> {
                    // User enabled high accuracy location, resume tracking with pending values
                    proceedToStartTracking()
                }
                RESULT_CANCELED -> {
                    // No location available at all, inform the user
                    Toast.makeText(this, getString(R.string.location_services_required), Toast.LENGTH_SHORT).show()
                    // Re-enable the button so the user can try again
                    viewModel.isTrackingPending.value = false
                    updateButtonStateFromViewModel()
                }
            }
        }
    }

    // Helper data class for tracking input
    data class TrackingInput(val course: String, val bib: String, val birthYear: String, val code: String)

    // Helper to get the latest user input or pending values
    private fun getTrackingInput(): TrackingInput {
        val course = pendingCourse ?: autocompleteCourse.text.toString()
        val bib = pendingBib ?: editBib.text.toString()
        val birthYear = pendingBirthYear ?: editBirthYear.text.toString()
        val code = pendingCode ?: editCode.text.toString()
        return TrackingInput(course, bib, birthYear, code)
    }

    // Centralized function to clear track and fetch/display track, then reset pending values
    private fun proceedToStartTracking() {
        // Always check location permissions before proceeding
        if (!hasAllLocationPermissions()) {
            // Save pending values so we can resume after permission is granted
            val (course, bib, birthYear, code) = getTrackingInput()
            pendingCourse = course
            pendingBib = bib
            pendingBirthYear = birthYear
            pendingCode = code
            requestForegroundLocationPermissions()
            return
        }
        buttonStartStop.isEnabled = false // Disable button while fetching
        val (course, bib, birthYear, code) = getTrackingInput()
        clearTrack(currentTrackPoints.isEmpty())
        fetchAndDisplayTrack(course, bib, birthYear, code)
        pendingCourse = null
        pendingBib = null
        pendingBirthYear = null
        pendingCode = null
    }

    // Custom InfoWindow for marker
    class CustomMarkerInfoWindow(mapView: MapView) : InfoWindow(R.layout.custom_marker_info_window, mapView) {
        override fun onOpen(item: Any?) {
            val marker = item as? Marker ?: return
            val view = mView
            val titleView = view.findViewById<TextView>(R.id.info_title)
            titleView.text = marker.title
            // Optionally, set icon tint here if needed
        }
        override fun onClose() {
            // No-op
        }
    }
}
