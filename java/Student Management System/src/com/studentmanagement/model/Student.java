package com.studentmanagement.model;

// Represents one student
public class Student {

    // Making fields private -> (Encapsulation) -> thus needed getter functions for controlled access to these private fields
    private final int id; // ids should not change once created -> thus making final
    private String name;
    private int age;
    private String course;

    public Student(int id, String name, int age, String course) {
        this.id = id;
        this.name = name;
        this.age = age;
        this.course = course;
    }

    public int getId() {
        return id;
    }

    public String getName() {
        return name;
    }

    public int getAge() {
        return age;
    }

    public String getCourse() {
        return course;
    }

    public void updateDetails(String name, int age, String course) {
        this.name = name;
        this.age = age;
        this.course = course;
    }

    @Override
    public String toString(){
        return "ID: " + id
                + ", Name: " + name
                + ", Age: " + age
                + ", Course: " + course;
    }
}