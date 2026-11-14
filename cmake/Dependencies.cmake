include(FetchContent)

FetchContent_Declare(JUCE
    GIT_REPOSITORY https://github.com/juce-framework/JUCE.git
    GIT_TAG 9.0.4
    GIT_SHALLOW TRUE)

FetchContent_Declare(Catch2
    GIT_REPOSITORY https://github.com/catchorg/Catch2.git
    GIT_TAG v3.16.1
    GIT_SHALLOW TRUE)

# SOURCE_SUBDIR points nowhere so only the sources arrive: the project's own
# CMakeLists builds its tools, and has no library target to link.
FetchContent_Declare(NeuralAmpModelerCore
    GIT_REPOSITORY https://github.com/sdatkinson/NeuralAmpModelerCore.git
    GIT_TAG v0.6.0
    GIT_SHALLOW TRUE
    GIT_SUBMODULES Dependencies/eigen
    SOURCE_SUBDIR no-cmake-project)

# RoughStomp's TONE3000 library (rs::t3k), at a pinned commit. Only its sources
# are used (SOURCE_SUBDIR points nowhere), compiled below against this build's
# JUCE: its own CMake target would compile JUCE's modules a second time.
FetchContent_Declare(RoughStomp
    URL https://github.com/dantaipan/roughstomp/archive/43365d9ae7fd2b0c458706b9038776edc6342d7f.tar.gz
    URL_HASH SHA256=36a640ebdee031eaf336395a33ca0525036eed15efc0ca0107c979431708805f
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    SOURCE_SUBDIR no-cmake-project)

FetchContent_MakeAvailable(JUCE Catch2 NeuralAmpModelerCore RoughStomp)

# JUCE modules are INTERFACE libraries whose sources compile into every target
# that links them. Compiling them once here stops the engine, app and tests each
# carrying a copy, which would otherwise collide at link time.
add_library(roughtrack_juce STATIC)

target_link_libraries(roughtrack_juce
    PRIVATE
        juce::juce_audio_utils
        juce::juce_cryptography
        juce::juce_dsp
    PUBLIC
        juce::juce_recommended_config_flags)

target_compile_definitions(roughtrack_juce
    PUBLIC
        DONT_SET_USING_JUCE_NAMESPACE=1
        JUCE_PLUGINHOST_AU=1
        JUCE_PLUGINHOST_VST3=1
        JUCE_STANDALONE_APPLICATION=1
        JUCE_USE_CURL=0
        JUCE_WEB_BROWSER=0)

# Linking the modules PRIVATE keeps their sources out of consumers, so their
# include paths and definitions have to be re-exported by hand.
target_include_directories(roughtrack_juce
    INTERFACE $<TARGET_PROPERTY:roughtrack_juce,INCLUDE_DIRECTORIES>)

target_compile_definitions(roughtrack_juce
    INTERFACE $<TARGET_PROPERTY:roughtrack_juce,COMPILE_DEFINITIONS>)

# NAM's model types register themselves from static objects that nothing refers
# to, so consumers link the whole archive or they'd be dropped.
file(GLOB roughtrack_nam_sources CONFIGURE_DEPENDS
    ${neuralampmodelercore_SOURCE_DIR}/NAM/*.cpp
    ${neuralampmodelercore_SOURCE_DIR}/NAM/wavenet/*.cpp)

add_library(roughtrack_nam STATIC ${roughtrack_nam_sources})

target_include_directories(roughtrack_nam SYSTEM
    PUBLIC
        ${neuralampmodelercore_SOURCE_DIR}
        ${neuralampmodelercore_SOURCE_DIR}/Dependencies/eigen
        ${neuralampmodelercore_SOURCE_DIR}/Dependencies/nlohmann)

target_compile_definitions(roughtrack_nam PUBLIC NAM_SAMPLE_FLOAT)

# TONE3000 (tone3000.com): sign-in, tone lists, models and downloads, from
# RoughStomp. The sign-in and downloads live in ~/Library/Application Support/
# TONE3000 Shared, named for neither app, so RoughStomp and RoughTrack share them.
set(roughtrack_t3k_dir ${roughstomp_SOURCE_DIR}/tone3000)

add_library(roughtrack_t3k STATIC
    ${roughtrack_t3k_dir}/src/Api.cpp
    ${roughtrack_t3k_dir}/src/Config.cpp
    ${roughtrack_t3k_dir}/src/Http.cpp
    ${roughtrack_t3k_dir}/src/Pkce.cpp
    ${roughtrack_t3k_dir}/src/Service.cpp
    ${roughtrack_t3k_dir}/src/Session.cpp
    ${roughtrack_t3k_dir}/src/Types.cpp)

target_include_directories(roughtrack_t3k PUBLIC ${roughtrack_t3k_dir}/include)
target_link_libraries(roughtrack_t3k PUBLIC roughtrack_juce)

# The publishable key (client ID): RoughStomp's, which TONE3000 allows RoughTrack
# to use so the two share a sign-in. It stays out of the repo: put it in
# tone3000_client_id.local (git ignores it) or configure with
# -DROUGHTRACK_T3K_CLIENT_ID=t3k_pub_... Without one, TONE3000 isn't offered.
set(ROUGHTRACK_T3K_CLIENT_ID "" CACHE STRING "TONE3000 publishable key (client ID); default: tone3000_client_id.local")
set(roughtrack_t3k_key "${ROUGHTRACK_T3K_CLIENT_ID}")
set(roughtrack_t3k_key_file "${CMAKE_CURRENT_LIST_DIR}/../tone3000_client_id.local")
if(roughtrack_t3k_key STREQUAL "" AND EXISTS "${roughtrack_t3k_key_file}")
    file(STRINGS "${roughtrack_t3k_key_file}" roughtrack_t3k_key LIMIT_COUNT 1)
    string(STRIP "${roughtrack_t3k_key}" roughtrack_t3k_key)
endif()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${roughtrack_t3k_key_file}")
if(roughtrack_t3k_key STREQUAL "")
    message(STATUS "TONE3000: no client ID (tone3000_client_id.local), so it won't be offered")
endif()
# RoughStomp's Config.cpp reads it under its own name.
target_compile_definitions(roughtrack_t3k PRIVATE ROUGHSTOMP_T3K_CLIENT_ID="${roughtrack_t3k_key}")
