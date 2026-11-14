add_executable(roughtrack_tests
    AudioDevicesTests.cpp
    AudioEngineTests.cpp
    StudioTests.cpp
    BounceTests.cpp
    ChannelStripTests.cpp
    ClipDragTests.cpp
    ControllerInputTests.cpp
    UpdateTests.cpp
    ClipTests.cpp
    ControlSurfaceTests.cpp
    CrashRecoveryTests.cpp
    CycleTests.cpp
    DropoutDetectorTests.cpp
    DrumTests.cpp
    GridTests.cpp
    InsertTests.cpp
    LatencyCalibratorTests.cpp
    LoopTests.cpp
    MetronomeTests.cpp
    MeterTests.cpp
    MidiTests.cpp
    PluginScannerTests.cpp
    SessionTests.cpp
    TakeRoundTripTests.cpp
    Tone3000Tests.cpp
    TunerTests.cpp)

target_link_libraries(roughtrack_tests PRIVATE
    roughtrack_core
    Catch2::Catch2WithMain)

target_compile_definitions(roughtrack_tests PRIVATE
    ROUGHTRACK_BENCH_PATH="$<TARGET_FILE:roughtrack_bench>"
    ROUGHTRACK_NAM_EXAMPLES="${neuralampmodelercore_SOURCE_DIR}/example_models")

add_dependencies(roughtrack_tests roughtrack_bench)

list(APPEND CMAKE_MODULE_PATH ${catch2_SOURCE_DIR}/extras)
include(Catch)
catch_discover_tests(roughtrack_tests)
