cmake_minimum_required(VERSION 3.14)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

project(cgproxy VERSION 0.18)

include(GNUInstallDirs)

add_compile_options(-Wall -Wextra -Wpedantic -Wno-unused-result -Wno-unused-parameter -Wl,--no-undefined)

# for clangd
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# option(with_execsnoop "enable program level proxy control feature, need bcc installed" ON)
option(build_execsnoop_dl "build libexecsnoop.so which will be dynamic loaded, otherwise built directly into cgproxy" ON)
option(build_static "build with static link prefered" OFF)
option(build_tools OFF)
option(build_test "for develop" OFF)

add_subdirectory(src)
add_subdirectory(execsnoop-kernel)
add_subdirectory(pack)
if (build_tools)
    add_subdirectory(tools)
endif()
if (build_test)
    add_subdirectory(test)
endif()

# instal scripts and other things
install(PROGRAMS cgproxyd TYPE BIN)
install(PROGRAMS cgnoproxy TYPE BIN)
install(PROGRAMS cgroup-tproxy.sh DESTINATION ${CMAKE_INSTALL_DATADIR}/cgproxy/scripts)
install(FILES cgproxy.service DESTINATION ${CMAKE_INSTALL_LIBDIR}/systemd/system)
install(FILES config.json DESTINATION ${CMAKE_INSTALL_FULL_SYSCONFDIR}/cgproxy)
install(FILES readme.md DESTINATION ${CMAKE_INSTALL_DOCDIR})

# man pages
set(man_gz ${PROJECT_SOURCE_DIR}/man/cgproxyd.1.gz ${PROJECT_SOURCE_DIR}/man/cgproxy.1.gz ${PROJECT_SOURCE_DIR}/man/cgnoproxy.1.gz)
add_custom_command(OUTPUT ${man_gz}
    COMMAND gzip -fk cgproxyd.1 cgproxy.1 cgnoproxy.1
    WORKING_DIRECTORY ${PROJECT_SOURCE_DIR}/man
)
add_custom_target(man ALL DEPENDS ${man_gz})
install(FILES ${man_gz} DESTINATION ${CMAKE_INSTALL_MANDIR}/man1/)
