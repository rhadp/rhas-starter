project(auto-apps)

cmake_minimum_required (VERSION 2.10)

include(GNUInstallDirs)

find_package (vsomeip3 2.6.0 REQUIRED)

# Remove /usr/include from vsomeip3 target to prevent -isystem /usr/include
if(TARGET vsomeip3)
    get_target_property(_vsomeip_inc vsomeip3 INTERFACE_INCLUDE_DIRECTORIES)
    if(_vsomeip_inc STREQUAL "/usr/include")
        set_target_properties(vsomeip3 PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "")
    endif()
endif()

# Prevent CMake from adding -isystem for /usr/include
# This is critical - adding /usr/include as -isystem breaks the compiler's default search order
list(APPEND CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES "/usr/include")

find_package( Boost 1.55 COMPONENTS system thread log REQUIRED )

# Remove /usr/include from ALL Boost targets to prevent -isystem /usr/include
foreach(_comp IN ITEMS headers system thread log atomic chrono date_time filesystem regex)
    if(TARGET Boost::${_comp})
        get_target_property(_inc Boost::${_comp} INTERFACE_INCLUDE_DIRECTORIES)
        if(_inc STREQUAL "/usr/include")
            set_target_properties(Boost::${_comp} PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "")
        endif()
    endif()
endforeach()

set (INSTALL_LIB_DIR ${CMAKE_INSTALL_LIBDIR} CACHE PATH "Installation directory for libraries")
set (INSTALL_BIN_DIR ${CMAKE_INSTALL_BINDIR} CACHE PATH "Installation directory for executables")
set (INSTALL_INCLUDE_DIR ${CMAKE_INSTALL_INCLUDEDIR} CACHE PATH "Installation directory for header files")

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Remove /usr/include from Boost target interface includes if present
# This prevents -isystem /usr/include which breaks header search order
if(TARGET Boost::boost)
    get_target_property(BOOST_INC Boost::boost INTERFACE_INCLUDE_DIRECTORIES)
    if(BOOST_INC STREQUAL "/usr/include")
        set_target_properties(Boost::boost PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "")
    endif()
endif()

add_executable(radio-service radio-service.cpp services.hpp radio-stations.cpp)
target_link_libraries(radio-service vsomeip3 ${Boost_LIBRARIES})

add_executable(radio-client radio-client.cpp services.hpp)
target_link_libraries(radio-client vsomeip3 ${Boost_LIBRARIES})

add_executable(engine-service engine-service.cpp services.hpp)
target_link_libraries(engine-service vsomeip3 ${Boost_LIBRARIES})

install (
    TARGETS radio-service radio-client engine-service
    RUNTIME DESTINATION "${INSTALL_BIN_DIR}" COMPONENT bin
)
