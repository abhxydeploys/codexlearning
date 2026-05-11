package com.studentmanagement.service;

import com.studentmanagement.model.Student;

import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.stream.Collectors;


// Handles add / view / search / update / delete logic
public class StudentService {
    private final List<Student> students = new ArrayList<>();

    public Optional<Student> findStudentById(int id){
        for(Student student: students) {
            if(student.getId() == id){
                return Optional.of(student);
            }
        }
        return Optional.empty();
    }

    public boolean addStudent(Student student) {
        if(findStudentById(student.getId()).isPresent()) {
            return false;
        }
        students.add(student);
        return true;
    }

    public String findAllStudents(){
        StringBuilder sb = new StringBuilder();
         for(Student student: students){
             sb.append(student.toString()).append(System.lineSeparator());
         }
         return sb.toString().trim();
    }

    public ArrayList<Student> getAllStudent(){
        if(students.isEmpty()){
            return new ArrayList<>();
        }
        return ArrayList<Student>(students);
    }

    public boolean updateStudent(Student studentToUpdate){
        for(int i = 0; i<students.size(); i++){
            if(students.get(i).getId() == studentToUpdate.getId()){
                students.set(i, studentToUpdate);
                return true;
            }
        }
        return false;
    }

    public boolean deleteStudent(Student student){
        return students.remove(student);
    }

    public boolean deleteStudentById(int id){
        return students.removeIf(s -> s.getId() == id);
    }

    public List<Student> searchStudentByName(String query){
        String q = query.trim().toLowerCase();
            return students.stream()
                    .filter(s -> {
                        String name = s.getName();
                        return name != null && name.toLowerCase().contains(q);
                    })
                    .collect(Collectors.toList());
    }
}
