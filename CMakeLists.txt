cmake_minimum_required(VERSION 3.8)
project(argus_bringup)

if(CMAKE_COMPILER_IS_GNUCXX OR CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  add_compile_options(-Wall -Wextra -Wpedantic)
endif()

find_package(ament_cmake REQUIRED)
find_package(rclcpp REQUIRED)

# Build executable
add_executable(argus_bringup_node src/main.cpp)
ament_target_dependencies(argus_bringup_node rclcpp)

install(TARGETS
  argus_bringup_node
  DESTINATION lib/${PROJECT_NAME}
)

# If you have these folders, this installs them (safe even if you add later)
install(DIRECTORY
  launch
  config
  rviz
  DESTINATION share/${PROJECT_NAME}
  OPTIONAL
)

if(BUILD_TESTING)
  find_package(ament_lint_auto REQUIRED)
  set(ament_cmake_copyright_FOUND TRUE)
  set(ament_cmake_cpplint_FOUND TRUE)
  ament_lint_auto_find_test_dependencies()
endif()

ament_package()

