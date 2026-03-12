import rclpy
from rclpy.node import Node
from sensor_msgs.msg import JointState
import math, time

rclpy.init()
node = Node('test_publisher')
pub = node.create_publisher(JointState, '/joint_states', 10)
t = 0.0

while rclpy.ok():
    msg = JointState()
    msg.header.stamp = node.get_clock().now().to_msg()
    msg.name = ['single_rrbot_joint1', 'single_rrbot_joint2']
    msg.position = [math.sin(t), math.cos(t)]
    pub.publish(msg)
    t += 0.05
    time.sleep(0.05)
