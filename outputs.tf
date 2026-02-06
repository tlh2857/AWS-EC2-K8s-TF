output "instance_id" {
  description = "EC2 Instance ID"
  value       = aws_instance.k8s_node.id
}

output "instance_public_ip" {
  description = "Public IP of the EC2 instance"
  value       = aws_instance.k8s_node.public_ip
}

output "instance_public_dns" {
  description = "Public DNS of the EC2 instance"
  value       = aws_instance.k8s_node.public_dns
}

output "ecr_repository_url" {
  description = "ECR Repository URL"
  value       = aws_ecr_repository.springapp.repository_url
}

output "spring_app_url" {
  description = "URL to access the Spring application"
  value       = "http://${aws_instance.k8s_node.public_ip}:30080"
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh -i <your-key>.pem ubuntu@${aws_instance.k8s_node.public_ip}"
}

output "kubectl_check_commands" {
  description = "Commands to check deployment status"
  value       = <<-EOT
    SSH into the instance and run:
      kubectl get nodes
      kubectl get pods -o wide
      kubectl get services
      kubectl logs -l app=springapp
      tail -f /var/log/userdata.log
  EOT
}
