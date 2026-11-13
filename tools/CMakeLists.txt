add_executable(roughtrack_bench
    Bench.cpp
    BuildDrumKit.cpp
    NativeViews.mm
    PluginWindow.cpp)

target_link_libraries(roughtrack_bench PRIVATE
    roughtrack_engine
    juce::juce_recommended_warning_flags)
