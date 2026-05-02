package com.studentmanagement.service;

import com.studentmanagement.model.Student;

import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

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
}
