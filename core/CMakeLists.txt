add_library(roughtrack_core STATIC
    source/Bridge.cpp
    source/ClipDrag.cpp
    source/ControllerInput.cpp
    source/HostedEditor.cpp
    source/Studio.cpp
    source/Updates.cpp)

# include/ is for C++ callers; bridge/ is the plain-C++ header Swift imports.
target_include_directories(roughtrack_core PUBLIC include bridge)
target_compile_definitions(roughtrack_core PUBLIC ROUGHTRACK_VERSION="${PROJECT_VERSION}")

target_link_libraries(roughtrack_core
    PUBLIC
        roughtrack_engine
    PRIVATE
        juce::juce_recommended_warning_flags)
